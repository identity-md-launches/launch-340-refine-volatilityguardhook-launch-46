# Integration and service handoff

Target **Sepolia only, chainId 11155111**, policy `univ4_hook v2`. Production hook constructor argument: `IPoolManager(0xe03a1074c86cfedd5c142c4f04f1a1536e203543)`. Token constructor has no arguments. Both contracts have immutable final behavior. Token/hookAdmin/treasury/LP policy owner is `0x09ec38170e94532eddb57c69dfc4f1fdcd0d4a60`; hookAdmin is policy metadata, not an onchain admin capability.

The requested manager address agrees with the [official Uniswap Sepolia deployment table](https://developers.uniswap.org/docs/protocols/v4/deployments#sepolia-11155111), consulted 2026-09-18 UTC. That table also lists these existing contracts:

| Contract | Sepolia address |
|---|---|
| PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| PositionManager | `0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4` |
| Quoter | `0x61b3f2011a92d183c7dbadbda940a7555ccf9227` |
| Universal Router (original) | `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b` |
| StateView | `0xe1dd9c3fa50edb962e442f60dfbc432e24537e4c` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

Live read-only RPC and explorer requests returned HTTP 403 in this worker environment; see [the read attempt](evidence/sepolia-read.json). Address-list agreement is established; live runtime/source equivalence and periphery `poolManager()` linkage are **not** claimed. Verifier/deployer must recheck chain ID, code, verified source and configured manager before admission. No fork rehearsal was run. Local tests deploy an actual pinned PoolManager rather than etching it for lifecycle testing.

## Pool identity and price

For final token T and mined hook H:

```
key = PoolKey(currency0=address(0), currency1=T,
              fee=uint24(3000), tickSpacing=int24(60), hooks=H)
PoolId = keccak256(abi.encode(address(0), T, uint24(3000), int24(60), H))
```

This is five 32-byte ABI words, **not** packed encoding. Sort arbitrary other currencies by their numerical address. Native ETH sorts first and is not WETH. Fee 3000 means static 0.3%. `sqrtPriceX96=792281625142643375935439503360000=10000*2^96` means currency1/currency0=10^8; with both 18 decimals this is **0.00000001 ETH per VGL**. The PoolId cannot be filled in before both final addresses exist.

Creation code is compiled VolatilityGuardHook bytecode followed by `abi.encode(manager)`; no owner argument. CREATE2 address is the low 20 bytes of `keccak256(0xff || factory || salt || keccak256(creationCode))`. Salt must produce `uint160(H)&0x3fff == 0x10c0`. Mine against the actual factory and exact signed creation bytes; a salt from local tests is not portable. Constructor and getHookPermissions independently enforce this bitmask.

## Factory bootstrap

Supply allocation: liquidity up to 8e26 units (80%), treasury 1e26 (10%), contributors 1e26 (10%). Factory/contributor service must enforce the 1-hour contributor lock and 30% per-wallet cap as defined by canonical service policy. This is not a global ERC20 wallet cap: such a cap would conflict with factory mint and 80% seeding. The factory supplies **zero native ETH** to liquidity. No additional helper is deployed. The deployer gas budget remains capped by the existing **0.3 Sepolia ETH** policy; it must estimate total authorized gas and decline if insufficient. No worker has additional funding, spending or signing authority.

`BootstrapMath.derive(budget, maxLiquidityPerTick)` uses pinned TickMath and SqrtPriceMath, entirely integer arithmetic. At the opening price, choose lower=`ceil(MIN_TICK/60)*60=-887220` (Solidity truncation toward zero at negative MIN_TICK yields the ceiling) and upper=`floor(getTickAtSqrtPrice(opening)/60)*60=184200`. This is the widest aligned token1-only interval: the current price is above its upper bound. Compute `L=floor(budget*2^96/(sqrt(upper)-sqrt(lower)))`, cap at core `Pool.tickSpacingToMaxLiquidityPerTick(60)`, and compute the actual rounded-up token1 debt with SqrtPriceMath. The resulting debt must be <=budget. Avoid floating-point logarithms or unchecked cast truncation. For budget 8e26, the test derives:

```
lower = -887220
upper = 184200
liquidity = 80064092962998534530849
token1 debt = 799999999999999999999992909
token0 debt = 0
unused liquidity allocation = 7091 VGL base units
```

The factory/service determines disposition of that allocation dust under canonical policy. These are reproducible calculations, not a receipt. Seed range begins approximately 16 ticks below opening, inside the restricted 30-tick bound. **Buy VGL with ETH first. Reverse swaps need accrued ETH liquidity.** Initially active liquidity is zero; the first buy crosses the small empty gap into the token-only interval. A reverse trade before a buy cannot extract non-existent ETH. Tests verify first buy, subsequent partial sell and full LP exit.

## Existing-periphery recipes

All instructions below are integration recipes for the operator/service, not transactions authorized to this worker. ABI layouts here refer to the original v4 periphery interface at [4d85e047e321d0c02134fec9044879c0cd00ea7d](https://github.com/Uniswap/v4-periphery/tree/4d85e047e321d0c02134fec9044879c0cd00ea7d). Later router releases add fields such as minHopPriceX36; never mix their layouts with the original router. Confirm each deployed ABI and manager link during verification. Hook data is empty `0x`; no end-user identity encoding is required. Existing verified periphery is required; `test/Router.sol` and mocks are local harnesses and must not be deployed.

**Quote.** Use `eth_call` (simulation, not STATICCALL) to Quoter `quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))` with `(key,zeroForOne,amountIn,0x)`. Decode `(uint256 amountOut,uint256 gasEstimate)`. `quoteExactOutputSingle` takes the same tuple with desired output and returns required input plus gas estimate. For ETH purchases zeroForOne=true; VGL sales=false. Quoter simulates and rolls back hook accounting; a quote neither reserves budget nor persists recovery. A state change or intervening trader can invalidate it.

**Preview limits.** `preview(key)` is a view (`eth_call` or on-chain STATICCALL) returning `NextSwapLimits(mode, ewma, currentTick, referenceTick, limitTicks, budgetUsed, budgetCap, stale, priceCheckPasses)`: exactly what the next swap's beforeSwap/afterSwap would enforce if it executes at the same `block.timestamp` against the same pool state. It applies the refresh a swap would perform first (volume refill, 900 s stale reset, tick integral, 30 s EWMA sample, mode transitions) but persists nothing. `status(id)` returns stored values without that refresh and can be stale; use `preview` for decisions and `status` only for history. It reverts `Uninitialized()` for an unknown pool and `InvalidPool()` if `key.hooks` is not this hook. Only hooks built from this source have it: the live Sepolia hook `0x7a49f192a9c4ac298990853f344fd29a5eb350c0` is immutable and does not, so a call there reverts. Detect this and fall back to quoting.

- `priceCheckPasses=false`: beforeSwap rejects every swap of any size with `PriceDeviation(|currentTick-referenceTick|, limitTicks)`. Do not submit. Only time or a mode change (for example, the restricted limit lifting in NORMAL) can clear it; re-preview later.
- Price envelope: the post-swap tick must lie within `limitTicks` of both `referenceTick` and `currentTick`, i.e. in `[max(ref,cur)-limit, min(ref,cur)+limit]`, or afterSwap reverts `PriceDeviation`. A UI can show this range as the maximum price impact. A direct PoolManager integrator can set `sqrtPriceLimitX96` to the edge tick's price (`getSqrtPriceAtTick(edge)`, plus 1 when zeroForOne so the swap does not stop on a boundary and read one tick lower). The swap then fills partially instead of reverting. The original Universal Router single-hop tuple has no price limit, so size the trade with the Quoter instead.
- Volume headroom is `budgetCap > budgetUsed ? budgetCap - budgetUsed : 0`. Saturate this: after a drop from NORMAL (cap 20,000) into a restricted mode (cap 5,000), `budgetUsed` can exceed the cap. afterSwap charges `cost = ceil(max(v0,v1) * 1e6 / L)`, where `v0 = ceil(|amount0| * sqrtPriceX96 / 2^96)` and `v1 = ceil(|amount1| * 2^96 / sqrtPriceX96)`. The amounts are the realized swap deltas, fee included; `sqrtPriceX96` is the pre-swap price; `L` is the smaller of pre- and post-swap active liquidity. The swap passes iff `cost <= headroom`. One unit more reverts `VolumeBudget(budgetCap+1, budgetCap)`. Near the price, cost is roughly 50 units per tick moved, whatever the liquidity.
- `stale=true`: the next swap resets history. The reference becomes the current tick, mode GUARDED, limit 30.
- Not covered by the struct: beforeSwap also reverts `LowLiquidity()` when active liquidity is non-zero and below 1,000, and afterSwap does so when post-swap liquidity is below 1,000. Read liquidity via StateView.
- Validity: the result is exact only for the calling block's timestamp and state. A transaction mined later can cross a 30 s sample, a 120 s transition, the 900 s stale boundary, or further refill. Any swap ahead of it in the block changes the pool. An on-chain router that calls `preview` in the same transaction immediately before the swap gets an exact answer. A UI must re-preview near submission, and it still needs slippage limits: a preview is not a reservation. `checkpoint(key)` persists the same refresh when a caller wants it on chain.

**Swap via original Universal Router.** Call `execute(bytes commands,bytes[] inputs,uint256 deadline)` with command `0x10` (V4_SWAP) and one input `abi.encode(actions,params)`. For exact input use actions `0x060c0f`:

1. `params[0]=abi.encode((key,zeroForOne,uint128(amountIn),uint128(minOut),bytes("")))` (one dynamic ExactInputSingleParams tuple).
2. `params[1]=abi.encode(currencyIn,uint256(maxInput))` (SETTLE_ALL).
3. `params[2]=abi.encode(currencyOut,uint256(minOut))` (TAKE_ALL).

For exact output use actions `0x080c0f` and first tuple `(key,zeroForOne,uint128(amountOut),uint128(maxIn),bytes(""))`. Set final TAKE_ALL minimum to desired output and SETTLE_ALL maximum to maxIn. ERC20 input requires token allowance to Permit2 and bounded Permit2 authorization for the router; native input requires msg.value. Append the router's native SWEEP command `0x04` with input `abi.encode(address(0),recipient,uint256(0))` when funding can exceed actual debit, particularly exact output; command bytes then `0x1004` and inputs has two entries. Use a real recipient and deadline and never leave refunds stranded. Periphery slippage checks, quote and simulation are essential in addition to this hook's limits.

**Mint or add LP liquidity via existing PositionManager.** Call `modifyLiquidities(bytes unlockData,uint256 deadline)`, where unlockData=`abi.encode(actions,params)`. For a new position use actions `0x020d14`: MINT_POSITION, SETTLE_PAIR, SWEEP native refunds. Mint parameters are separate ABI arguments `(key,int24(lower),int24(upper),uint256(L),uint128(amount0Max),uint128(amount1Max),owner,bytes(""))`; settlement parameters `(currency0,currency1)`; sweep `(address(0),recipient)`. Token-only initial mint sets amount0Max=0, amount1Max<=8e26 and msg.value=0. Permit2 authorizes the existing PositionManager to pay ERC20 debt. For later additions use INCREASE_LIQUIDITY=0x00 with `(tokenId,uint256(deltaL),uint128(amount0Max),uint128(amount1Max),bytes(""))` followed by settlement/refund. Do not use deprecated delta-derived liquidity actions.

**Exit/collect.** Approved NFT owner uses DECREASE_LIQUIDITY=0x01 with `(tokenId,uint256(deltaL),uint128(amount0Min),uint128(amount1Min),bytes(""))`, then TAKE_PAIR=0x11 with `(currency0,currency1,recipient)`. Actions `0x0111`, wrapped in modifyLiquidities. Zero deltaL collects fees. Full burn uses BURN_POSITION=0x03 with `(tokenId,uint128(amount0Min),uint128(amount1Min),bytes(""))`, then TAKE_PAIR. Obtain current position liquidity and meaningful minimum amounts from simulation. Hook modes never gate these actions; NFT ownership and core/periphery settlement checks still apply.

## Errors and review boundary

`artifacts/abis/` is exported from actual implementation, not handwritten. `docs/errors.json` records selectors/signatures. Hook errors:

| Error | Meaning/action |
|---|---|
| Unauthorized() | Callback caller is not immutable manager; use existing periphery/core flow. |
| InvalidManager() | Constructor manager is zero or has no code. |
| InvalidPool() | Wrong key.hooks or repeated initialization. |
| Uninitialized() | No successful afterInitialize for this PoolId. |
| CallbackOrder() | Missing/mismatched before callback or nested pending operation. |
| InvalidAmount() | Zero/oversized request or core delta signs inconsistent with direction. |
| LowLiquidity() | Nonzero pre-L below floor or post-L below floor. Add liquidity; LP exits still work. |
| PriceDeviation(uint256,uint256) | Actual absolute tick distance exceeds permitted limit. Requote smaller trade/wait for healthy history; do not simply remove slippage. |
| VolumeBudget(uint256,uint256) | Used+realized cost exceeds current cap. Wait for refill; splitting/identity changes do not reset it. |
| HookAddressNotValid(address) | Constructor permission bits do not match mined address. |

Token errors are InvalidRecipient(), InsufficientBalance(), InsufficientAllowance(). Core may wrap a hook error as WrappedError(address target,bytes4 selector,bytes reason,bytes details), containing HookCallFailed(); unwrap reason and match its first four bytes against the implementation ABI. Core price limits, no liquidity, settlement imbalance or periphery slippage can independently revert. Reverts are not persisted state transitions.

Separate launch.json assignment owns the canonical manifest. Review must compare these constructor/flags/pool/owner/allocation/gas facts with that manifest, following supplied service guidance. Policy enforcement, signatures/artifact linkage, accepted GitHub publication in the configured org, attestation and deployment are service work. The operator ultimately compares published source, deployed verified contracts and seeded pool. This source submission does not wait for future URLs or receipts and does not claim them.
