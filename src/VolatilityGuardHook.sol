// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @notice Immutable pool-local risk limits. No custody, fee overrides, identities or admin.
contract VolatilityGuardHook {
    using StateLibrary for IPoolManager;
    uint160 public constant FLAGS = (1 << 12) | (1 << 7) | (1 << 6);
    uint256 public constant WINDOW = 300;
    uint256 public constant STALE = 900;
    uint128 public constant MIN_LIQUIDITY = 1000;
    uint256 private constant Q96 = 1 << 96;
    IPoolManager public immutable poolManager;
    enum Mode {
        NORMAL,
        WARMUP,
        GUARDED,
        RECOVERY
    }

    struct Observation {
        uint64 time;
        int128 cumulative;
    }

    struct Guard {
        uint64 last;
        uint64 sampleTime;
        uint64 since;
        uint64 volumeTime;
        int24 tick;
        int24 sampleTick;
        uint24 ewma;
        uint8 head;
        uint8 count;
        Mode mode;
        int128 cumulative;
        uint32 used;
        bool initialized;
        Observation[16] observations;
    }

    struct Pending {
        PoolId id;
        uint160 price;
        uint128 liquidity;
        int24 tick;
        int24 referenceTick;
        uint24 limit;
        bool active;
    }

    /// @notice What the next swap's beforeSwap/afterSwap would enforce at block.timestamp.
    struct NextSwapLimits {
        Mode mode;
        uint24 ewma;
        int24 currentTick;
        int24 referenceTick;
        uint24 limitTicks;
        uint256 budgetUsed;
        uint256 budgetCap;
        bool stale;
        bool priceCheckPasses;
    }

    /// @dev Guard fields as _refresh leaves them; computed by _next without writing state.
    struct Next {
        uint64 since;
        uint64 sampleTime;
        int24 sampleTick;
        int24 mean;
        uint24 ewma;
        uint8 head;
        uint8 count;
        Mode mode;
        bool stale;
        bool sampled;
        int128 cumulative;
        uint32 used;
    }
    mapping(PoolId => Guard) private guards;
    Pending private pending;
    error Unauthorized();
    error InvalidManager();
    error InvalidPool();
    error Uninitialized();
    error CallbackOrder();
    error InvalidAmount();
    error LowLiquidity();
    error PriceDeviation(uint256 deviation, uint256 limit);
    error VolumeBudget(uint256 used, uint256 cap);
    event ModeChanged(PoolId indexed id, Mode mode);
    event Observed(PoolId indexed id, int24 tick, int24 twap, uint24 ewma);

    constructor(IPoolManager manager) {
        if (address(manager) == address(0) || address(manager).code.length == 0) revert InvalidManager();
        poolManager = manager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick) external onlyManager returns (bytes4) {
        _key(key);
        if (pending.active) revert CallbackOrder();
        Guard storage g = guards[key.toId()];
        if (g.initialized) revert InvalidPool();
        g.initialized = true;
        _reset(g, tick);
        g.mode = Mode.WARMUP;
        emit ModeChanged(key.toId(), g.mode);
        return IHooks.afterInitialize.selector;
    }

    /// @notice Anyone may persist a health transition, including after a reverted swap.
    function checkpoint(PoolKey calldata key) external {
        _key(key);
        if (pending.active) revert CallbackOrder();
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        _refresh(key.toId(), tick, poolManager.getLiquidity(key.toId()));
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _key(key);
        if (pending.active) revert CallbackOrder();
        // Manager accounting is int128; reject pathological requests before taking absolute values.
        if (
            params.amountSpecified == 0 || params.amountSpecified > type(int128).max
                || params.amountSpecified < -int256(type(int128).max)
        ) revert InvalidAmount();
        PoolId id = key.toId();
        (uint160 price, int24 tick,,) = poolManager.getSlot0(id);
        uint128 liquidity = poolManager.getLiquidity(id);
        Next memory n = _refresh(id, tick, liquidity);
        uint24 limit = _limit(n);
        int24 refTick = n.mean;
        _check(tick, refTick, limit);
        if (liquidity != 0 && liquidity < MIN_LIQUIDITY) revert LowLiquidity();
        pending = Pending(id, price, liquidity, tick, refTick, limit, true);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyManager
        returns (bytes4, int128)
    {
        _key(key);
        PoolId id = key.toId();
        Pending memory p = pending;
        if (!p.active || PoolId.unwrap(p.id) != PoolId.unwrap(id)) revert CallbackOrder();
        (, int24 tick,,) = poolManager.getSlot0(id);
        _check(tick, p.referenceTick, p.limit);
        _check(tick, p.tick, p.limit);
        uint128 liquidity = poolManager.getLiquidity(id);
        if (liquidity < MIN_LIQUIDITY) revert LowLiquidity();
        if (p.liquidity != 0 && p.liquidity < liquidity) liquidity = p.liquidity;
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        if (params.zeroForOne ? (d0 > 0 || d1 < 0) : (d1 > 0 || d0 < 0)) revert InvalidAmount();
        uint256 v0 = FullMath.mulDivRoundingUp(_abs(d0), p.price, Q96);
        uint256 v1 = FullMath.mulDivRoundingUp(_abs(d1), Q96, p.price);
        uint256 cost = FullMath.mulDivRoundingUp(v0 > v1 ? v0 : v1, 1e6, liquidity);
        Guard storage g = guards[id];
        uint256 cap = _cap(g.mode);
        uint256 used = uint256(g.used) + cost;
        if (used > cap) revert VolumeBudget(used, cap);
        g.used = uint32(used);
        // Integrals were advanced using the pre-swap tick. Post-swap tick applies only to future time.
        g.tick = tick;
        delete pending;
        return (IHooks.afterSwap.selector, 0);
    }

    function status(PoolId id) external view returns (Mode mode, uint24 ewma, uint32 used, int24 twap, uint8 count) {
        Guard storage g = guards[id];
        if (!g.initialized) revert Uninitialized();
        return (g.mode, g.ewma, g.used, _twap(g), g.count);
    }

    /// @notice Limits the next swap faces if it executes at block.timestamp, including the refresh
    /// status() omits. Read-only: nothing is persisted, so a later block or intervening swap changes it.
    function preview(PoolKey calldata key) external view returns (NextSwapLimits memory) {
        _key(key);
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        Next memory n = _next(guards[id], tick, poolManager.getLiquidity(id));
        uint24 limit = _limit(n);
        return NextSwapLimits(
            n.mode, n.ewma, tick, n.mean, limit, n.used, _cap(n.mode), n.stale, _distance(tick, n.mean) <= limit
        );
    }

    function _key(PoolKey calldata key) private view {
        if (address(key.hooks) != address(this)) revert InvalidPool();
    }

    function _reset(Guard storage g, int24 tick) private {
        g.last = uint64(block.timestamp);
        g.sampleTime = g.last;
        g.since = g.last;
        g.tick = tick;
        g.sampleTick = tick;
        g.cumulative = 0;
        g.head = 0;
        g.count = 1;
        g.observations[0] = Observation(g.last, 0);
        g.ewma = 0;
    }

    function _refresh(PoolId id, int24 tick, uint128 liquidity) private returns (Next memory n) {
        Guard storage g = guards[id];
        n = _next(g, tick, liquidity);
        // At most one transition per refresh: a stale reset enters GUARDED with since = now, so
        // the healthy branch cannot move it on in the same call.
        if (n.mode != g.mode) emit ModeChanged(id, n.mode);
        g.last = uint64(block.timestamp);
        g.sampleTime = n.sampleTime;
        g.since = n.since;
        g.volumeTime = uint64(block.timestamp);
        g.tick = tick;
        g.sampleTick = n.sampleTick;
        g.ewma = n.ewma;
        g.head = n.head;
        g.count = n.count;
        g.mode = n.mode;
        g.cumulative = n.cumulative;
        g.used = n.used;
        if (n.stale || n.sampled) g.observations[n.head] = Observation(uint64(block.timestamp), n.cumulative);
        emit Observed(id, tick, n.mean, n.ewma);
    }

    function _next(Guard storage g, int24 tick, uint128 liquidity) private view returns (Next memory n) {
        if (!g.initialized) revert Uninitialized();
        uint256 elapsed = block.timestamp - g.last;
        uint256 refill = (block.timestamp - g.volumeTime) * 20_000 / WINDOW;
        n.used = refill >= g.used ? 0 : uint32(g.used - refill);
        n.mode = g.mode;
        n.since = g.since;
        n.stale = elapsed > STALE;
        if (n.stale) {
            // _reset (head, cumulative and ewma zero), then GUARDED.
            n.sampleTime = uint64(block.timestamp);
            n.since = n.sampleTime;
            n.sampleTick = tick;
            n.count = 1;
            n.mode = Mode.GUARDED;
        } else {
            n.cumulative = g.cumulative + int128(int256(g.tick) * int256(elapsed));
            n.sampleTime = g.sampleTime;
            n.sampleTick = g.sampleTick;
            n.ewma = g.ewma;
            n.head = g.head;
            n.count = g.count;
            if (block.timestamp - g.sampleTime >= 30) {
                uint256 movement = _distance(tick, g.sampleTick);
                n.ewma = uint24((uint256(g.ewma) * 7 + _min(movement, 2000)) / 8);
                n.sampleTick = tick;
                n.sampleTime = uint64(block.timestamp);
                n.head = (g.head + 1) % 16;
                if (n.count < 16) ++n.count;
                n.sampled = true;
            }
        }
        Observation memory latest =
            n.stale || n.sampled ? Observation(uint64(block.timestamp), n.cumulative) : g.observations[n.head];
        n.mean = _mean(g, uint64(block.timestamp), n.cumulative, tick, n.head, n.count, latest);
        bool unhealthy = liquidity < MIN_LIQUIDITY || n.ewma > 100 || _distance(tick, n.mean) > 200;
        if (unhealthy) {
            n.mode = Mode.GUARDED;
            n.since = uint64(block.timestamp);
        } else if (block.timestamp - n.since >= 120 && n.mode != Mode.NORMAL) {
            // GUARDED -> RECOVERY; RECOVERY or WARMUP -> NORMAL.
            n.mode = n.mode == Mode.GUARDED ? Mode.RECOVERY : Mode.NORMAL;
            n.since = uint64(block.timestamp);
        }
    }

    function _limit(Next memory n) private pure returns (uint24) {
        return n.mode == Mode.NORMAL ? uint24(_min(200, 40 + uint256(n.ewma) * 2)) : 30;
    }

    function _cap(Mode mode) private pure returns (uint256) {
        return mode == Mode.NORMAL ? 20_000 : 5_000;
    }

    // Target a 300-second window, retaining its predecessor rather than discarding
    // history at the boundary. With sparse calls this is a longer, conservative window.
    function _twap(Guard storage g) private view returns (int24) {
        return _mean(g, g.last, g.cumulative, g.tick, g.head, g.count, g.observations[g.head]);
    }

    /// @dev TWAP over g's ring as it would stand with the given head values; slot `head` reads as `latest`.
    function _mean(
        Guard storage g,
        uint64 last,
        int128 cumulative,
        int24 tick,
        uint8 head,
        uint8 count,
        Observation memory latest
    ) private view returns (int24) {
        Observation memory best = latest;
        uint256 cutoff = last > WINDOW ? last - WINDOW : 0;
        bool predecessor;
        for (uint256 i; i < count; ++i) {
            Observation memory o = i == head ? latest : g.observations[i];
            if (o.time <= cutoff) {
                if (!predecessor || o.time > best.time) best = o;
                predecessor = true;
            } else if (!predecessor && o.time < best.time) {
                best = o;
            }
        }
        uint256 duration = last - best.time;
        if (duration == 0) return tick;
        int256 sum = int256(cumulative) - best.cumulative;
        int256 mean = sum / int256(duration);
        if (sum < 0 && sum % int256(duration) != 0) --mean;
        return int24(mean);
    }

    function _check(int24 tick, int24 referenceTick, uint256 limit) private pure {
        uint256 diff = _distance(tick, referenceTick);
        if (diff > limit) revert PriceDeviation(diff, limit);
    }

    function _distance(int24 a, int24 b) private pure returns (uint256) {
        return _abs(int256(a) - b);
    }

    function _abs(int256 value) private pure returns (uint256) {
        return uint256(value < 0 ? -value : value);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
