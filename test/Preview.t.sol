// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GuardFixture} from "./Guard.t.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {VolatilityGuardHook as Hook} from "../src/VolatilityGuardHook.sol";

/// @dev preview() taken immediately before a swap, at the same timestamp, must describe exactly what
/// beforeSwap and afterSwap then enforce. Each probe observes the hook's own enforcement: the Observed
/// event (reference tick, ewma), PriceDeviation arguments (deviation, limit), VolumeBudget arguments
/// (used, cap) and the persisted mode.
contract PreviewTest is GuardFixture {
    using StateLibrary for IPoolManager;

    event Observed(PoolId indexed id, int24 tick, int24 twap, uint24 ewma);

    function setUp() public override {
        super.setUp();
        // Keep probes that walk the tick far from the start inside active liquidity.
        router.modify(key, ModifyLiquidityParams(-6000, 6000, 1e22, 0));
    }

    function tick() internal view returns (int24 t) {
        (, t,,) = IPoolManager(address(manager)).getSlot0(key.toId());
    }

    function wrapped(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev Exact-input swap of `amount` that stops at `target` at the latest.
    function toward(int24 target, uint256 amount) internal view returns (SwapParams memory) {
        bool down = target < tick();
        uint160 limit = TickMath.getSqrtPriceAtTick(target);
        // Stopping exactly on a lower tick boundary leaves the pool one tick below it.
        return SwapParams(down, -int256(amount), down ? limit + 1 : limit);
    }

    function swapTo(int24 target) internal {
        router.swap(key, toward(target, 1e24));
    }

    function distance(int24 x, int24 y) internal pure returns (uint256) {
        return x > y ? uint256(int256(x) - y) : uint256(int256(y) - x);
    }

    /// @dev Checks preview() against beforeSwap/afterSwap at the current timestamp without changing state.
    /// Moves toward the reference so that `limitTicks` from the current tick is the binding bound.
    function probe(bool upWhenCentred) internal returns (Hook.NextSwapLimits memory l) {
        l = hook.preview(key);
        int24 pre = tick();
        assertEq(l.currentTick, pre, "currentTick");
        assertEq(l.budgetCap, l.mode == Hook.Mode.NORMAL ? 20_000 : 5_000, "cap");
        uint256 expected = l.mode == Hook.Mode.NORMAL ? 40 + 2 * uint256(l.ewma) : 30;
        assertEq(l.limitTicks, expected > 200 ? 200 : expected, "limit formula");
        assertEq(l.priceCheckPasses, distance(pre, l.referenceTick) <= l.limitTicks, "priceCheckPasses");
        // preview() is a view: calling it twice at the same state gives the same answer.
        assertEq(keccak256(abi.encode(hook.preview(key))), keccak256(abi.encode(l)), "deterministic");

        if (!l.priceCheckPasses) {
            // beforeSwap refuses any swap, reporting the previewed reference distance and limit.
            vm.expectRevert(
                wrapped(
                    IHooks.beforeSwap.selector,
                    abi.encodeWithSelector(
                        Hook.PriceDeviation.selector, distance(pre, l.referenceTick), uint256(l.limitTicks)
                    )
                )
            );
            router.swap(key, SwapParams(true, -1e15, TickMath.MIN_SQRT_PRICE + 1));
            return l;
        }

        bool up = pre < l.referenceTick || (pre == l.referenceTick && upWhenCentred);
        int24 edge = up ? pre + int24(l.limitTicks) : pre - int24(l.limitTicks);
        uint256 snap = vm.snapshotState();

        // One tick past the edge: afterSwap rejects it against the pre-swap tick with the previewed limit.
        SwapParams memory over = toward(up ? edge + 1 : edge - 1, 1e24);
        vm.expectRevert(
            wrapped(
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(Hook.PriceDeviation.selector, uint256(l.limitTicks) + 1, uint256(l.limitTicks))
            )
        );
        router.swap(key, over);

        // Exactly limitTicks: passes, and beforeSwap reports the previewed reference tick and ewma.
        SwapParams memory exact = toward(edge, 1e24);
        vm.expectEmit(true, false, false, true, address(hook));
        emit Observed(key.toId(), pre, l.referenceTick, l.ewma);
        router.swap(key, exact);
        assertEq(tick(), edge, "reached edge");
        (Hook.Mode mode, uint24 ewma, uint32 used,,) = hook.status(key.toId());
        assertEq(uint8(mode), uint8(l.mode), "mode");
        assertEq(ewma, l.ewma, "ewma");
        assertGt(used, l.budgetUsed, "charged from previewed usage");
        assertLe(used, l.budgetCap, "within previewed cap");
        vm.revertToState(snap);
    }

    function test_previewMatchesSwapsAcrossWindows() public {
        // Just initialised: WARMUP, reference is the initial tick.
        Hook.NextSwapLimits memory l = probe(true);
        assertEq(uint8(l.mode), uint8(Hook.Mode.WARMUP));
        assertEq(l.referenceTick, 0);
        assertEq(l.limitTicks, 30);
        assertFalse(l.stale);
        swapTo(-20);

        // Inside one 30 s sample window: no new sample, EWMA unchanged.
        vm.warp(block.timestamp + 10);
        l = probe(false);
        assertEq(l.ewma, 0);
        assertEq(l.referenceTick, -20);
        swapTo(-40);

        // Across a sample: EWMA takes in the 40-tick movement since the last sample.
        vm.warp(block.timestamp + 25);
        l = probe(true);
        assertEq(l.ewma, 5);
        assertEq(l.referenceTick, -35);
        (,, uint32 usedBefore,,) = hook.status(key.toId());
        assertLt(l.budgetUsed, usedBefore, "refill applied");

        // Across the 120 s recovery: WARMUP -> NORMAL at the swap itself, with no checkpoint.
        vm.warp(block.timestamp + 90);
        (Hook.Mode stored,,,,) = hook.status(key.toId());
        assertEq(uint8(stored), uint8(Hook.Mode.WARMUP), "status() is stale");
        l = probe(true);
        assertEq(uint8(l.mode), uint8(Hook.Mode.NORMAL));
        assertEq(l.budgetCap, 20_000);
        // Probes are rolled back, so the 1035 s sample was never stored: this one sees the same 40 ticks.
        assertEq(l.ewma, 5);
        assertEq(l.limitTicks, 50);
        swapTo(0);

        // Past 900 s: reset to GUARDED, reference is the current tick.
        vm.warp(block.timestamp + 901);
        l = probe(false);
        assertTrue(l.stale);
        assertEq(uint8(l.mode), uint8(Hook.Mode.GUARDED));
        assertEq(l.referenceTick, 0);
        assertEq(l.ewma, 0);
        assertEq(l.limitTicks, 30);
        swapTo(-10);

        // GUARDED -> RECOVERY -> NORMAL, each at the swap.
        vm.warp(block.timestamp + 120);
        l = probe(true);
        assertEq(uint8(l.mode), uint8(Hook.Mode.RECOVERY));
        swapTo(5);
        vm.warp(block.timestamp + 120);
        l = probe(false);
        assertEq(uint8(l.mode), uint8(Hook.Mode.NORMAL));
    }

    function test_previewReportsFailingPriceCheck() public {
        normal();
        swapTo(-38);
        // A liquidity dip forces GUARDED; once restored the pool is healthy but the restricted 30-tick
        // limit now excludes the current tick, so beforeSwap refuses every swap.
        router.modify(key, ModifyLiquidityParams(-600, 600, -int256(1e22), 0));
        router.modify(key, ModifyLiquidityParams(-6000, 6000, -int256(1e22 - 500), 0));
        hook.checkpoint(key);
        router.modify(key, ModifyLiquidityParams(-6000, 6000, int256(1e22 - 500), 0));
        vm.warp(block.timestamp + 1);
        Hook.NextSwapLimits memory l = probe(true);
        assertEq(uint8(l.mode), uint8(Hook.Mode.GUARDED));
        assertEq(l.limitTicks, 30);
        assertFalse(l.priceCheckPasses);
    }

    /// @dev budgetCap - budgetUsed is exactly the cost afterSwap accepts; one unit more is VolumeBudget.
    function test_budgetHeadroomIsExact() public {
        headroom(false);
    }

    function test_budgetHeadroomIsExactInNormal() public {
        headroom(true);
    }

    function headroom(bool inNormal) internal {
        if (inNormal) normal();
        Hook.NextSwapLimits memory l = hook.preview(key);
        for (uint256 i; l.budgetCap - l.budgetUsed > 600; ++i) {
            swap(i % 2 == 0, -int256(5e18));
            l = hook.preview(key);
        }
        assertEq(uint8(l.mode), uint8(inNormal ? Hook.Mode.NORMAL : Hook.Mode.WARMUP));
        // Toward the reference and capped at the price envelope, so only the budget can refuse.
        int24 pre = tick();
        int24 edge = pre >= l.referenceTick ? pre - int24(l.limitTicks) : pre + int24(l.limitTicks);
        // Smallest input the budget refuses; cost rises by at most one unit per step at this liquidity.
        uint256 lo = 1;
        uint256 hi = 1e21;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            try router.swap(key, toward(edge, mid)) {
                lo = mid;
            } catch (bytes memory reason) {
                assertEq(bytes4(unwrap(reason)), Hook.VolumeBudget.selector, "only the budget refuses");
                hi = mid;
            }
            vm.revertToState(snap);
        }
        SwapParams memory over = toward(edge, hi);
        vm.expectRevert(
            wrapped(
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(Hook.VolumeBudget.selector, l.budgetCap + 1, l.budgetCap)
            )
        );
        router.swap(key, over);
        router.swap(key, toward(edge, lo));
        (,, uint32 used,,) = hook.status(key.toId());
        assertEq(used, l.budgetCap, "the whole previewed headroom was usable");
    }

    function unwrap(bytes memory reason) internal pure returns (bytes memory inner) {
        assertEq(bytes4(reason), CustomRevert.WrappedError.selector);
        bytes memory args = new bytes(reason.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = reason[i + 4];
        }
        (,, inner,) = abi.decode(args, (address, bytes4, bytes, bytes));
    }

    function test_previewDoesNotWriteAndMatchesCheckpoint() public {
        swapTo(-20);
        vm.warp(block.timestamp + 125);
        (Hook.Mode m0, uint24 e0, uint32 u0, int24 t0, uint8 c0) = hook.status(key.toId());
        Hook.NextSwapLimits memory l = hook.preview(key);
        (Hook.Mode m1, uint24 e1, uint32 u1, int24 t1, uint8 c1) = hook.status(key.toId());
        assertEq(abi.encode(m0, e0, u0, t0, c0), abi.encode(m1, e1, u1, t1, c1));
        hook.checkpoint(key);
        (m1, e1, u1, t1,) = hook.status(key.toId());
        assertEq(abi.encode(l.mode, l.ewma, l.budgetUsed, l.referenceTick), abi.encode(m1, e1, uint256(u1), t1));
    }

    function test_previewUnknownOrForeignPool() public {
        PoolKey memory other = key;
        other.fee = 100;
        vm.expectRevert(Hook.Uninitialized.selector);
        hook.preview(other);
        other = key;
        other.hooks = IHooks(address(0));
        vm.expectRevert(Hook.InvalidPool.selector);
        hook.preview(other);
    }

    function testFuzz_previewMatchesSwaps(uint16[6] memory gaps, uint8[6] memory moves, bool[6] memory ups) public {
        for (uint256 i; i < gaps.length; ++i) {
            // Mix same-window, sample, recovery and stale gaps.
            uint256 gap = gaps[i] % 4 == 0 ? bound(gaps[i], 0, 29) : bound(gaps[i], 0, 1200);
            vm.warp(block.timestamp + gap);
            Hook.NextSwapLimits memory l = probe(ups[i]);
            if (!l.priceCheckPasses) {
                hook.checkpoint(key);
                continue;
            }
            // Advance with a real swap inside the previewed envelope.
            int24 pre = tick();
            int24 step = int24(uint24(bound(moves[i], 1, l.limitTicks / 3)));
            int24 target = pre < l.referenceTick || (pre == l.referenceTick && ups[i]) ? pre + step : pre - step;
            swapTo(target);
        }
    }
}
