# Orbital — a Uniswap v4 hook for Paradigm's Orbital stableswap, with a Reactive depeg circuit breaker

Orbital is a Uniswap v4 hook that prices swaps on an **N-dimensional sphere** instead of a flat
curve. One hook holds one multi-token stablecoin pool (2–8 coins). Every v4 pool whose two currencies
are both basket coins is routed through the shared sphere; LPs add liquidity to the sphere in
concentrated "ticks" that are automatically **pinned (isolated)** once a coin leaves the peg region
the tick covers.

A keeper-free **circuit breaker** completes the design: a Reactive Smart Contract on Reactive Lasna
watches a Chainlink `AnswerUpdated` feed for one of the basket coins and, when the price leaves the
peg band, sends a cross-chain callback to Unichain Sepolia. The callback contract is the hook's
`guardian` and can only **pause**; resuming is owner-only so a human reviews the depeg first.

```
Chainlink feed (origin chain) ──AnswerUpdated──▶ OrbitalDepegReactive (Reactive Lasna, 5318007)
                                                      │ emit Callback(1301, OrbitalDepegCallback, …)
                                                      ▼
                  Reactive callback proxy (Unichain Sepolia, 1301) ──depeg(rvmId, feed, price, round)──▶
                  OrbitalDepegCallback ──guardianPause()──▶ OrbitalHook  (swaps + deposits halt; withdrawals keep working)
```

## Contents

| Path | What |
| --- | --- |
| `src/OrbitalHook.sol` | The hook: sphere math integration, LP accounting, swaps via `beforeSwap` + return-delta, pause/guardian. |
| `src/libraries/OrbitalMath.sol` | Fixed-point Orbital geometry: torus invariant, exact-in/exact-out solvers, tick-boundary step. |
| `src/base/BaseHook.sol` | Minimal v4 hook base: the three implemented callbacks are PoolManager-only, everything else reverts in a fallback; address-bit validation in the constructor. |
| `src/HookFlags.sol` | Permission bit constants and address matching. |
| `src/OrbitalToken.sol` | ORB launch token: fixed 1,000,000,000 × 10¹⁸ supply minted to the deployer, nothing else. |
| `src/reactive/OrbitalDepegReactive.sol` | Reactive Smart Contract for Reactive Lasna (the watcher). |
| `src/reactive/OrbitalDepegCallback.sol` | Destination-chain callback target and hook guardian. |
| `src/reactive/IReactive.sol` | Locally declared Reactive interfaces (no `reactive-lib` dependency in the audited core). |
| `script/DeployOrbital.s.sol` | Deployment: deploys token + callback, mines the hook salt, deploys the hook with the callback as guardian and `OWNER` as owner from the constructor, binds the callback, hands it over. Works identically in tests and under `--broadcast`. |
| `test/` | 85 Foundry tests (success and failure paths, fuzz); `test/mocks/MockERC20.sol` is the mock the floor suite uses, `test/mocks/HookableERC20.sol` a coin with an issuer pause and a receiver hook; `test/utils/BasketHarness.sol` builds a hook for any basket. |
| `lib/` | Vendored as plain files: `v4-core` (46c6834), `forge-std` (c6fa5d8), `solmate` (89365b8). No submodules. |

Toolchain: `solc = "0.8.26"`, EVM `cancun`, optimizer 200 runs, no `via_ir`, no `ffi`, no filesystem
access. `forge build`, `forge test` and `forge fmt --check` pass.

## How Orbital works here

Notation follows the paper. Reserves are WAD (18-decimal) fixed point in *virtual* coordinates.

* Sphere for one tick of radius `r`: `Σ (r − xᵢ)² = r²`. Equal-price point `xᵢ = r(1 − 1/√N)`.
* `v = (1,…,1)/√N`; `α = x·v = S/√N` (S = Σxᵢ) is the distance along the equal-price axis;
  `‖w‖ = √(Q − S²/N)` (Q = Σxᵢ²) the distance away from it. Moving away from the peg **increases** α.
* A tick is parameterised per unit radius by `k_norm ∈ (√N − 1, (N−1)/√N]`. While the interior's
  normalised position `α_int / r_int` is below `k_norm` the tick is **interior**; once it reaches it,
  the tick is **boundary**: pinned to the plane `x·v = k`, trading only along the circle of radius
  `s = r·√(1 − (√N − k_norm)²)`.
* Interior ticks consolidate into one sphere (`r_int = Σ r`); boundary ticks consolidate into one
  circle (`k_bound = Σ k`, `s_bound = Σ s`). The global invariant is the torus

  `(α − k_bound − r_int·√N)² + (‖w‖ − s_bound)² = r_int²`.

* **α is not monotonic along a trade.** Adding token i and removing token j lowers α while
  `xᵢ < xⱼ` (the trade heads back towards the peg) and raises it afterwards; the marginal price is 1
  exactly at `xᵢ = xⱼ`. Pinned ticks therefore rejoin the interior on the *falling* part of a path
  and interior ticks pin on the *rising* part, each where the path meets the tick's plane. Because
  every `k_norm` exceeds `√N − 1`, the interior can only reach its own equal-price point once every
  tick has rejoined it, so `‖w‖ ≥ s_bound` holds on every valid state (the hook refuses to commit a
  state that violates it: `BoundaryInverted`).
* **Capital efficiency.** A tick's reserve of any coin can never fall below
  `x_min = k/√N − s·√((N−1)/N)` per unit radius, so an LP only deposits `x − x_min` of each coin;
  the rest is virtual. With N = 3 a tick at `k_norm = 0.74` deposits ~23% of what a full-range tick
  deposits for the same radius (test `test_concentratedTickNeedsLessCapital`).
* **Depeg isolation.** Once pinned, a tick's reserve of the depegging coin is capped at
  `r·(k/√N + s·√((N−1)/N))` and it stops absorbing it, while a full-range tick keeps absorbing up to
  `r`. `test_depegIsolatesConcentratedLiquidity` checks: the pinned tick absorbs < 1/5 of what the
  full-range tick absorbs on a deepening depeg, stays under the geometric cap, and loses less of the
  still-pegged coin per unit radius.

### Swaps

`beforeSwap` consumes the whole specified amount (v4's own curve sees a zero-amount swap) and returns a
`BeforeSwapDelta`. Exact-input and exact-output are both supported. The engine (`_simulate`) works on
memory copies:

1. Consolidate the ticks under the current boundary mask.
2. Solve the torus invariant for the unspecified amount by bisection (`solveOut` / `solveIn`),
   rounding in the pool's favour. The solver refuses trades that cannot reach the surface
   (`InsufficientLiquidity`) and the hook refuses trades past a token's pole (`SwapTooLarge`).
3. Find the first tick plane the segment meets and split the trade there (`tryPlaneStep`, closed
   form). While `xᵢ < xⱼ` (α falling) the candidate is the highest pinned tick, met on the j-heavy
   image of its plane; otherwise the lowest interior tick whose plane lies at or below the segment's
   end, met on the i-heavy image. A tick whose recorded status already disagrees with the interior
   position (a state left exactly on a plane, or the one-unit rounding a deposit or withdrawal
   introduces; slack `POSITION_TOLERANCE = 1e-15`) is flipped where the trade stands. Flip the tick,
   re-consolidate and continue (each tick leaves and rejoins the interior at most once per trade, so
   at most `2 × levels + 2` segments). Crossings emit `LevelCrossed`.
4. After the last segment, refuse the trade if it pushed a token past its pole (`SwapTooLarge`) or
   ended with `‖w‖ < s_bound` (`BoundaryInverted`, unreachable by construction).

Fees (`feePpm`, ≤ 1%) are charged on the input and accrue to every LP **in proportion to radius,
pinned or not** (`feeGrowth` per unit radius, MasterChef-style). This is a deliberate rule: a pinned
tick keeps trading along its boundary circle as the pool's direction rotates (it absorbs part of
every trade between the other coins, e.g. ~4% of a sale when it holds a third of the radius in the
depeg test), so it is not inactive liquidity; the paper prescribes no split, and a per-trade
attribution would cost a loop over ticks on every swap. The trade-off is that during a depeg the
interior carries most of the flow for a radius-proportional share. Reserves and fees are held as
**ERC-6909 claims on the PoolManager** owned by the hook: a swap mints input claims and burns output
claims, so settlement never depends on the manager's spot balance of a token. The swapper's router
settles tokens as usual. Tokens with fewer than 18 decimals are scaled internally; sub-unit rounding
stays with the pool. Swaps are refused while the hook is inside its own settlement (`Reentrancy`):
the manager is unlocked during a deposit, withdrawal or fee payout, and a basket coin with a receiver
hook must not be able to trade from inside that window.

### Liquidity

* `deposit(level, radius, maxAmounts)` — pays the caller's pending fees first, then pulls
  `transferFrom` the exact deposit for `radius` at that tick (see `previewDeposit`), parks it in the
  PoolManager and mints claims to the hook. `maxAmounts` is the slippage guard. `radius ≥ MIN_RADIUS`
  (1e18, about 0.42 tokens per coin at full range).
  * The first deposit opens the pool at the equal-price point (rounded up by ~1e-18 so it never
    opens outside the sphere).
  * A deposit is **priced on the tick's own surface**: a pinned tick on its circle
    (`k·r/√N + s·r·ŵ`), an interior tick on the sphere of radius `r_int` through the interior's
    current direction, scaled to `radius`. The pool's state point may sit inside the torus by some
    dust (pool-favoured rounding, or an exact-in swap whose output rounds to zero raw units keeps the
    whole input); pricing from the projected point means that dust is never copied in proportion to
    the new radius, so the most a later trader can take is the dust itself.
  * With only pinned liquidity left (`r_int = 0`), a deposit into a tick above the highest pinned
    plane opens a fresh interior exactly on that plane (the one point consistent with every pinned
    tick staying pinned); a deposit into a tick at or below it is a boundary deposit.
* `withdraw(level, radius, minAmounts)` — pays pending fees, then returns the tick's proportional
  share of the interior's actual reserves (or its circle point if pinned) minus the virtual floor,
  capped at the hook's claim balance of each coin. A partial withdrawal must leave at least
  `MIN_RADIUS` in the position and in the tick (`ResidualTooSmall`). When the last radius leaves,
  the virtual reserves are cleared so the next opener starts from the equal-price point; rounding
  dust stays with the manager. **Works while paused.** `collectFees(level)` pays accrued fees.
* **Per-coin delivery.** Withdrawals and fee payouts deliver each coin on its own: if a coin's
  transfer reverts (issuer pause, blocklisted LP), the LP receives that coin as an **ERC-6909 claim
  on the PoolManager** instead (`ClaimsDelivered`) and the other coins move normally. Once the coin
  moves again, `redeemClaims(token, amount, to)` turns the claim back into tokens (approve the hook
  on the manager with `setOperator`/`approve` first). A redeem has no fallback. A basket coin that
  burns all gas on a failing transfer would still make the fallback run on 1/64 of the gas; pick
  basket coins accordingly.
* v4 `modifyLiquidity` on an Orbital pool reverts (`LiquidityLivesInHook`). Pools where either
  currency is not a basket coin are **pass-through**: plain v4 pools whose only hook behaviour is
  the pause (used by the ORB launch pool).

### Pause model

| Who | Can |
| --- | --- |
| `guardian` (the Reactive callback contract) | `guardianPause()` — idempotent, pause only |
| `owner` | `pause()`, `unpause()`, `setGuardian`, `setFee` (≤ 1%), `transferOwnership` |
| anyone | `withdraw`, `collectFees`, `redeemClaims`, views — even when paused |

Paused blocks: swaps on every pool using the hook (Orbital and pass-through), `deposit`, and new pool
initialisation. It never blocks withdrawals or v4 liquidity removal. Nobody can move LP funds.

## Hook configuration record (OpenZeppelin Wizard shape)

```json
{
  "hook": "BaseCustomCurve",
  "name": "OrbitalHook",
  "pausable": true,
  "currencySettler": false,
  "safeCast": false,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": true,
    "beforeRemoveLiquidity": false,
    "afterAddLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": true,
    "afterSwap": false,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": true,
    "afterSwapReturnDelta": false,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "ownable",
  "info": { "license": "MIT" }
}
```

Notes on the record: the type is the *custom curve* pattern (the whole AMM math is replaced), built on
this repo's own `BaseHook` because v4-periphery no longer ships one and OpenZeppelin `uniswap-hooks`
is not vendored. `currencySettler` is not needed — settlement is done directly with
`poolManager.mint/burn/sync/settle/take`. Shares are tracked internally per `(level, lp)` rather than
as a token. "Pausable" is implemented by hand (two roles) rather than with OpenZeppelin `Pausable`.
Address flags: `0x2888` (`BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_SWAP | BEFORE_SWAP_RETURN_DELTA`
= 10376). The address must be mined for exactly these bits (`DeployOrbital.mineSalt`).

Key sections: `constructor(IPoolManager, owner, guardian, basket[], decimals[], kNorms[], feePpm)`
validates everything and makes **no external calls** (decimals are passed in) so the creation code can
be verified on a bare chain; `getHookPermissions()` declares the four flags; `_beforeInitialize`
registers basket pairs; `_beforeAddLiquidity` refuses v4 liquidity on Orbital pools;
`_beforeSwap` → `_execute` → `_simulate`.

## Security review (per the v4 security checklist)

* Every implemented callback is `onlyPoolManager`; the `IHooks` callbacks the hook does not implement
  (and any unknown selector) land in a fallback that reverts `HookNotImplemented` — the PoolManager
  never calls a callback whose address bit is unset, and leaving them out of the dispatcher keeps the
  runtime at 24,220 bytes, under the EIP-170 limit of 24,576. `unlockCallback` is PoolManager-only
  (and the manager only calls back the contract that called `unlock`).
* `beforeSwapReturnDelta` is the justified custom-curve use: the hook takes the specified amount and
  returns the unspecified one; deltas net to zero on both paths (tested through the v4 swap router).
* No `DELEGATECALL`, `SELFDESTRUCT`, proxies or upgrade path (the math library is `internal`; the floor
  scan confirms). No hardcoded addresses. No `tx.origin`, no timestamps in pricing.
* Reentrancy: `deposit`/`withdraw`/`collectFees`/`redeemClaims` are `nonReentrant`, and `beforeSwap`
  refuses to run while one of them is in progress (the manager is unlocked then, so a coin with a
  receiver hook could otherwise swap from inside a payout). Fee payouts happen before any state is
  mutated; token pulls use a `safeTransferFrom` that tolerates non-bool tokens.
* Loops are bounded: ≤ 8 tokens, ≤ 8 ticks, ≤ 2·levels+2 trade segments, bisection ≤ ~100 steps.
* Fee-on-transfer tokens are **not** supported (deposit pulls the exact amount; a fee-on-transfer
  coin would under-fund the manager and the settle would revert). Rebasing tokens are not supported.
  Pausable/blocklisting coins are: a frozen coin is delivered as a claim, never blocking the others.
* Risk score (matrix): permissions ≈ 10 (beforeInitialize 1 + beforeAddLiquidity 2 + beforeSwap 3 +
  beforeSwapReturnDelta 4), external calls 1, state complexity 4, admin surface 2, token handling 2
  ⇒ ~19/33, **High**: a professional audit is required before holding real funds. Tests are not an
  audit; an independent adversarial review is a release gate.

Known limitations, stated plainly:

* Gas: swaps run a bisection with a square root per step; a one-segment swap costs roughly
  0.9–1.4M gas in tests. Acceptable for an L2 testnet, a target for a Newton-step optimisation later.
* Concentrated ticks are leveraged like Uniswap v3 ranges: exposure to a depegging coin is **capped**
  and the tick stops absorbing it, but the loss *per dollar deposited* on a moderate move can exceed a
  full-range tick's. The protection is against catastrophic exposure, not against all IL.
* If every tick is boundary (`r_int = 0`) — pinned ticks left behind after the interior LPs exit —
  swaps revert `NoInteriorLiquidity` until someone opens a new interior position (any deposit into a
  tick above the highest pinned plane does; it opens exactly on that plane). Nothing is locked and
  no one has to withdraw first.
* Sub-unit rounding (for 6-decimal coins) leaves wei-level dust with the PoolManager that nobody can
  claim, and an exact-in swap may leave up to one raw unit of the output coin inside the surface for
  the next trader; round trips can gain at most a few wei (`testFuzz_roundTripNeverProfits` allows
  10 wei). Deposit pricing is immune to that dust (see Liquidity).
* Fees are split by radius including pinned ticks (see Swaps): an explicit design choice.
* Routers must set `amountOutMinimum`; the hook enforces no slippage on behalf of swappers.

## The ORB launch token

`OrbitalToken` is the standard launch token: name `Orbital`, symbol `ORB`, 18 decimals, exactly
10²⁷ minor units minted to `msg.sender` in a no-argument constructor; no owner, mint, pause, blocklist,
fee or upgrade functions. The brief did not ask for token-side fees or special supply, and none were
added; swap fees live in the hook. ORB is **not** a member of the stablecoin basket — a pool pairing
ORB with any currency under this hook is a pass-through v4 pool (plain concentrated liquidity, pause
applies). The launch manifest writes the hook's PoolManager argument as `"$poolManager"`.

## Deployment parameters

Chain and address facts below come from the Reactive Network documentation as read on 2026-10-01 and
must be re-verified with `cast code` before use; they are configuration, never constants in source.

| Parameter | Value / source |
| --- | --- |
| Destination chain | Unichain Sepolia, chain id **1301** (OP Stack; time-ordered, no priority-fee bidding) |
| Reactive chain | Reactive Lasna, chain id **5318007**, RPC `https://lasna-rpc.rnk.dev/` |
| Reactive system contract (Lasna) | `0x0000000000000000000000000000000000fffFfF` (constant in `OrbitalDepegReactive`, per protocol) |
| Reactive callback proxy on Unichain Sepolia | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4` (unverified here; constructor arg `callbackProxy`) |
| Reactive callback proxy on Ethereum Sepolia | `0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA` (if the feed origin is Sepolia and a second breaker is wanted) |
| `REACTIVE_IGNORE` | `0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad` |
| Chainlink topic | `keccak256("AnswerUpdated(int256,uint256,uint256)")`; price = `topic_1`, round = `topic_2` |
| Chainlink feed | Choose one basket coin's USD aggregator (**the aggregator, not the proxy**, since `AnswerUpdated` is emitted by the aggregator). Origin chain id + address are constructor args; the address can be re-pointed later with `setFeed` on the Lasna copy (Chainlink rotates aggregators behind its proxy). Chainlink lists Unichain Sepolia feeds at data.chain.link; not verified in this repo. |
| Peg / band | `pegPrice` in feed decimals (e.g. `1e8`), `bandBps` (e.g. 200 = ±2%); non-positive prices also trip |
| Hook basket | 2–8 ERC-20 stablecoins, with decimals, e.g. USDC (6), USDT (6), DAI (18) |
| Ticks (`kNorms`, WAD) | ascending, in `(√N − 1, (N−1)/√N]`; N = 3: `(0.7321, 1.1547]`; the tests use `0.74e18, 0.95e18, 1.15e18` |
| `feePpm` | ≤ 10,000 (1%); tests use 400 (0.04%) |
| Hook flags | `0x2888` (10376) |
| CREATE2 deployer | Foundry's `0x4e59b44847b379578588920cA78FbF26c0B4956C` when broadcasting `new{salt:}`; mine for that deployer |

### Order of operations

1. **Unichain Sepolia**: `forge script script/DeployOrbital.s.sol --rpc-url <unichain-sepolia> --broadcast`
   with `POOL_MANAGER`, `OWNER`, `BASKET`, `DECIMALS`, `K_NORMS`, `FEE_PPM`, `CALLBACK_PROXY`, `RVM_ID`
   set (comma-separated lists). `RVM_ID` is the EOA that will deploy the reactive contract in step 3.
   The script deploys ORB, deploys `OrbitalDepegCallback` (first owned by the broadcaster, hook
   unbound), mines the salt, deploys the hook **with `OWNER` as owner and the callback as guardian
   from its constructor**, binds the callback to the hook (`setHook`, one-shot) and transfers the
   callback to `OWNER` (use a multisig). No owner-only call is ever made on the hook, so the script
   behaves identically in tests and under `--broadcast` (`test/Deploy.t.sol` runs both).
2. Initialise pools for each basket pair with `hooks = <hook>` (fee/tickSpacing are irrelevant for
   Orbital pairs), and the ORB launch pool (pass-through). LPs `approve` the hook and call `deposit`.
3. **Reactive Lasna**: deploy `OrbitalDepegReactive(originChainId, feedAggregator, 1301, callback,
   callbackGasLimit, pegPrice, bandBps)` from the `RVM_ID` EOA, funded with REACT; it subscribes in
   its constructor. Verify `isReactVm() == false` on the Lasna copy.
4. Fund `OrbitalDepegCallback` with native ETH on Unichain Sepolia: the callback proxy charges it for
   delivered callbacks through `pay()`. Keep both contracts funded; `withdraw` is owner-only.
5. Rehearse: push a test feed update out of band (or lower `bandBps` on a second deployment) and
   confirm `Paused(callback, true)` on the hook; then `unpause()` as owner.

### Breaker semantics

* **One callback per excursion.** The ReactVM copy keeps a latch per emitting aggregator: the first
  out-of-band round emits `DepegDetected` and the `Callback`; later out-of-band rounds only emit
  `DepegPersists` (no callback, nothing charged on the destination chain) until an in-band round
  re-arms the latch (`PriceInBand`). The ReactVM copy's state can only change through `react`, so
  there is no owner re-arm; a new excursion after an in-band round trips again.
* **Resuming during a sustained depeg.** `unpause()` is not undone by the same excursion (the latch
  holds). If the owner wants the breaker to fire again while the feed is still out of band, it will
  only do so after the price has been back in band once. To silence the breaker entirely:
  `setGuardian(0)` on the hook, or `setRvmId(0)` on the callback.
* **Destination-side checks.** `depeg` records the highest round acted on per aggregator and ignores
  a round at or below it (`StaleRoundIgnored`: duplicates and delayed deliveries), and acknowledges
  a delivery that finds the hook already paused without calling it (`DepegAlreadyPaused`).
* **Aggregator rotation.** `AnswerUpdated` comes from the aggregator behind Chainlink's proxy, which
  Chainlink replaces over time. The Lasna copy's owner re-points the subscription in one transaction
  with `setFeed(newAggregator)` (drops the old subscription best-effort, subscribes the new one). The
  ReactVM copy does not filter on the address: it reacts to whatever the subscription delivers and
  names the emitting aggregator in the payload, so rounds (which restart at 1 on a new aggregator)
  are tracked per aggregator on the destination side.

### Operational responsibilities

* **Owner (multisig)**: review every pause before `unpause()`; rotate `guardian` if the callback
  contract is redeployed; keep `feePpm` sane; never hold user funds (the design gives the owner no
  way to).
* **Breaker operator**: keep the Lasna contract funded (REACT) and the callback contract funded (ETH);
  monitor `DepegDetected`/`DepegPersists`/`PriceInBand` on Lasna and
  `DepegPauseTriggered`/`DepegAlreadyPaused`/`StaleRoundIgnored` on Unichain Sepolia; alert on
  `Paused`. **Liveness check**: `PriceInBand` must keep arriving at the feed's heartbeat; if it stops,
  compare `feed()` on the Lasna copy with the Chainlink proxy's `aggregator()` and `setFeed` if they
  differ. Chainlink heartbeat/deviation determines reaction latency; the breaker is as fast as the
  feed update plus Reactive finality, not instantaneous.
* **LPs**: deposits require exact proportions (use `previewDeposit`); a coin that cannot be
  transferred at withdrawal time arrives as a PoolManager claim, redeemable with `redeemClaims`; the
  pool is a testnet artefact until audited.

### Assumptions

* Inside the ReactVM, `react()` transactions are sent **from the RVM id** (the EOA that deployed the
  reactive contract) and the system contract has no code there. `react` therefore only checks that
  it runs in the ReactVM copy (`ReactiveVmOnly` otherwise), exactly like `reactive-lib`'s
  `AbstractReactive.vmOnly`; it does not check the sender. This matches live `react(LogRecord)`
  transactions observed on Reactive Lasna by the independent reviewer (`from` = RVM id); it was not
  exercised against a live node from this repository. The callback proxy overwrites the first
  160-bit argument of the payload with the RVM id (tests use a mock proxy that performs the same
  substitution).
* Chainlink emits `AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt)`
  from the **aggregator** contract; subscribe to that address, not the feed proxy.
* The verifier deploys the hook from the attested creation code onto a bare chain; the constructor
  therefore takes decimals as arguments and never calls the basket tokens.

## Tests

```
forge build && forge test && forge fmt --check
```

85 tests across seven suites:

* `OrbitalHook.t.sol` — permissions match the address bits; callbacks refuse non-PoolManager callers;
  pool registration (Orbital vs pass-through, refused while paused); constructor validation; first
  deposit at the equal point; concentrated ticks need less capital; deposit/withdraw slippage and bad
  inputs; v4 liquidity refused on Orbital pools; exact-in/exact-out swaps match quotes and stay near
  par; 6-decimal coin both ways; round trips never profit; fees accrue by radius and are collectable;
  oversize swaps and empty pools revert; a large trade pins the tight tick and a reverse trade unpins
  it; depeg isolation (pinned tick stops absorbing, geometric cap, less IL per radius); guardian can
  only pause, owner only unpauses; pause blocks swaps/deposits but not withdrawals; pass-through pool
  works and pauses; fuzz: invariant preserved, round trip never profits, exact-out ≥ par.
* `OrbitalTicks.t.sol` — a return trade through the peg unpins the tick at its plane (one crossing,
  consistent state, nothing to skim after the next deposit); random trades/deposits/withdrawals keep
  the point on the torus, `‖w‖ ≥ s_bound` and every tick on the right side of its plane (fuzz); a
  tick left exactly on its plane and nudged by a deposit still rejoins on the next return trade;
  with only pinned liquidity left an interior reopens on the pinned plane, trading resumes, a
  boundary deposit without interior works, and a return trade unpins.
* `OrbitalLiquidity.t.sol` — a MIN_RADIUS pool pushed inside the sphere by a zero-output swap does
  not skim the next depositor (one raw unit buys par plus the donated dust at most); residual floor
  on withdrawals; a full exit clears the virtual reserves and the next opener is priced like the
  first; a swap from inside the hook's fee payout is refused and the state seen there is the
  committed state; hook actions are non-reentrant; a frozen coin is delivered as a claim (fees and
  withdrawals) while the others move, and is redeemable later; `redeemClaims` failure paths;
  everyone can leave in full after the reviewer's deposit/swap/withdraw sequence and after random
  activity (fuzz).
* `Reactive.t.sol` — end-to-end depeg → `Callback` → proxy delivery → hook paused, duplicate
  delivery ignored; one callback per excursion, re-armed by an in-band round; the owner's resume is
  not undone by the same excursion; already-paused and stale-round deliveries acknowledged; above-band
  and non-positive prices trip; in-band does nothing; `react` runs only in the ReactVM copy (from the
  RVM id) and refuses unexpected logs; the Reactive Network copy subscribes, unsubscribes and follows
  an aggregator rotation (`setFeed`, best-effort unsubscribe); the ReactVM copy follows the rotated
  aggregator with separate latch and rounds; config validation; payment hooks; callback refuses
  non-proxy and wrong/zero RVM id; callback fails when it is not the guardian; admin, funding, and
  one-shot hook binding.
* `OrbitalMath.t.sol` — sqrt floor fuzz, √N, tick geometry, invariant at the equal point, exact-in
  solver lands on the surface, exact-out inverts exact-in, refusal paths, plane step picks the
  requested image and reports unreachable planes, hook flags.
* `OrbitalToken.t.sol`, `Deploy.t.sol` — supply/transfer/no admin surface; `deploy(Config)` wires
  guardian and ownership at a mined address, both called directly and under `vm.startBroadcast`
  through the default CREATE2 deployer.

Tests read no environment variables and do not depend on the caller address; they pass in any order
and in parallel. The pinned floor suites (`Hook.protected.t.sol`, `Token.protected.t.sol`) were also run
locally against the real creation code (hook with constructor args naming non-existent token
addresses, flags 10376; token with decimals 18) and passed 9/9.

## Open items for the launch

* Verified Chainlink aggregator address and origin chain for the chosen basket coin.
* Confirm the Unichain Sepolia callback proxy address on the Reactive docs at deploy time.
* Multisig for `OWNER`; funding plan for both breaker contracts; monitoring/alerting on `Paused`.
* Independent adversarial review before any real funds.
