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
| `src/base/BaseHook.sol` | Minimal v4 hook base (PoolManager-only callbacks, address-bit validation). |
| `src/HookFlags.sol` | Permission bit constants and address matching. |
| `src/OrbitalToken.sol` | ORB launch token: fixed 1,000,000,000 × 10¹⁸ supply minted to the deployer, nothing else. |
| `src/reactive/OrbitalDepegReactive.sol` | Reactive Smart Contract for Reactive Lasna (the watcher). |
| `src/reactive/OrbitalDepegCallback.sol` | Destination-chain callback target and hook guardian. |
| `src/reactive/IReactive.sol` | Locally declared Reactive interfaces (no `reactive-lib` dependency in the audited core). |
| `script/DeployOrbital.s.sol` | Deployment: mines the hook salt, deploys token + hook + callback, wires guardian, hands ownership over. |
| `test/` | 62 Foundry tests (success and failure paths, fuzz); `test/mocks/MockERC20.sol` is the mock the floor suite uses. |
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
3. If the interior position would cross a tick's `k_norm`, split the trade exactly at the plane
   (`planeStep`, closed form), flip the tick's status, re-consolidate and continue (bounded by
   `2 × levels + 1` segments). Crossings emit `LevelCrossed`.

Fees (`feePpm`, ≤ 1%) are charged on the input and accrue to every LP in proportion to radius
(`feeGrowth` per unit radius, MasterChef-style). Reserves and fees are held as **ERC-6909 claims on
the PoolManager** owned by the hook: a swap mints input claims and burns output claims, so settlement
never depends on the manager's spot balance of a token. The swapper's router settles tokens as usual.
Tokens with fewer than 18 decimals are scaled internally; sub-unit rounding stays with the pool.

### Liquidity

* `deposit(level, radius, maxAmounts)` — pulls `transferFrom` the exact deposit for `radius` at that
  tick (see `previewDeposit`), parks it in the PoolManager and mints claims to the hook. The first
  deposit opens the pool at the equal-price point. `maxAmounts` is the slippage guard.
* `withdraw(level, radius, minAmounts)` — returns the tick's proportional reserve vector minus the
  virtual floor. **Works while paused.** `collectFees(level)` pays accrued fees.
* v4 `modifyLiquidity` on an Orbital pool reverts (`LiquidityLivesInHook`). Pools where either
  currency is not a basket coin are **pass-through**: plain v4 pools whose only hook behaviour is
  the pause (used by the ORB launch pool).

### Pause model

| Who | Can |
| --- | --- |
| `guardian` (the Reactive callback contract) | `guardianPause()` — idempotent, pause only |
| `owner` | `pause()`, `unpause()`, `setGuardian`, `setFee` (≤ 1%), `transferOwnership` |
| anyone | `withdraw`, `collectFees`, views — even when paused |

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

* Every callback is `onlyPoolManager`; unimplemented ones revert `HookNotImplemented`; `unlockCallback`
  is PoolManager-only (and the manager only calls back the contract that called `unlock`).
* `beforeSwapReturnDelta` is the justified custom-curve use: the hook takes the specified amount and
  returns the unspecified one; deltas net to zero on both paths (tested through the v4 swap router).
* No `DELEGATECALL`, `SELFDESTRUCT`, proxies or upgrade path (the math library is `internal`; the floor
  scan confirms). No hardcoded addresses. No `tx.origin`, no timestamps in pricing.
* Reentrancy: `deposit`/`withdraw`/`collectFees` are `nonReentrant`; swaps execute inside the
  PoolManager lock; token pulls use a `safeTransferFrom` that tolerates non-bool tokens.
* Loops are bounded: ≤ 8 tokens, ≤ 8 ticks, ≤ 2·levels+1 trade segments, bisection ≤ ~100 steps.
* Fee-on-transfer tokens are **not** supported (deposit pulls the exact amount; a fee-on-transfer
  coin would under-fund the manager and the settle would revert). Rebasing tokens are not supported.
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
* If every tick is boundary (`r_int = 0`) the pool cannot trade or accept interior deposits until an
  LP withdraws from a boundary tick (`NoInteriorLiquidity`); this needs the whole basket to sit far
  off-peg at once.
* Sub-unit rounding (for 6-decimal coins) leaves wei-level dust with the PoolManager that nobody can
  claim; round trips can gain at most a few wei (`testFuzz_roundTripNeverProfits` allows 10 wei).
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
| Chainlink feed | Choose one basket coin's USD aggregator (**the aggregator, not the proxy**, since `AnswerUpdated` is emitted by the aggregator). Origin chain id + address are constructor args. Chainlink lists Unichain Sepolia feeds at data.chain.link; not verified in this repo. |
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
   The script deploys ORB, mines the salt, deploys the hook, deploys `OrbitalDepegCallback`, sets it
   as guardian and transfers hook ownership to `OWNER` (use a multisig).
2. Initialise pools for each basket pair with `hooks = <hook>` (fee/tickSpacing are irrelevant for
   Orbital pairs), and the ORB launch pool (pass-through). LPs `approve` the hook and call `deposit`.
3. **Reactive Lasna**: deploy `OrbitalDepegReactive(originChainId, feedAggregator, 1301, callback,
   callbackGasLimit, pegPrice, bandBps)` from the `RVM_ID` EOA, funded with REACT; it subscribes in
   its constructor. Verify `isReactVm() == false` on the Lasna copy.
4. Fund `OrbitalDepegCallback` with native ETH on Unichain Sepolia: the callback proxy charges it for
   delivered callbacks through `pay()`. Keep both contracts funded; `withdraw` is owner-only.
5. Rehearse: push a test feed update out of band (or lower `bandBps` on a second deployment) and
   confirm `Paused(callback, true)` on the hook; then `unpause()` as owner.

### Operational responsibilities

* **Owner (multisig)**: review every pause before `unpause()`; rotate `guardian` if the callback
  contract is redeployed; keep `feePpm` sane; never hold user funds (the design gives the owner no
  way to).
* **Breaker operator**: keep the Lasna contract funded (REACT) and the callback contract funded (ETH);
  monitor `DepegDetected`/`PriceInBand` on Lasna and `DepegPauseTriggered` on Unichain Sepolia; alert on
  `Paused`. Chainlink heartbeat/deviation determines reaction latency; the breaker is as fast as the
  feed update plus Reactive finality, not instantaneous.
* **LPs**: deposits require exact proportions (use `previewDeposit`); the pool is a testnet artefact
  until audited.

### Assumptions

* `react()` is invoked with `msg.sender == 0x…fffFfF` inside the ReactVM, and the callback proxy
  overwrites the first 160-bit argument of the payload with the RVM id (reactive contract deployer).
  Both follow the Reactive docs/`reactive-lib`; the exact behaviour was not exercised against a live
  Reactive node here (tests use a mock proxy that performs the same substitution).
* Chainlink emits `AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt)`
  from the **aggregator** contract; subscribe to that address, not the feed proxy.
* The verifier deploys the hook from the attested creation code onto a bare chain; the constructor
  therefore takes decimals as arguments and never calls the basket tokens.

## Tests

```
forge build && forge test && forge fmt --check
```

62 tests across five suites:

* `OrbitalHook.t.sol` — permissions match the address bits; callbacks refuse non-PoolManager callers;
  pool registration (Orbital vs pass-through, refused while paused); constructor validation; first
  deposit at the equal point; concentrated ticks need less capital; deposit/withdraw slippage and bad
  inputs; v4 liquidity refused on Orbital pools; exact-in/exact-out swaps match quotes and stay near
  par; 6-decimal coin both ways; round trips never profit; fees accrue by radius and are collectable;
  oversize swaps and empty pools revert; a large trade pins the tight tick and a reverse trade unpins
  it; depeg isolation (pinned tick stops absorbing, geometric cap, less IL per radius); guardian can
  only pause, owner only unpauses; pause blocks swaps/deposits but not withdrawals; pass-through pool
  works and pauses; fuzz: invariant preserved, round trip never profits, exact-out ≥ par.
* `Reactive.t.sol` — end-to-end depeg → `Callback` → proxy delivery → hook paused; above-band and
  non-positive prices trip; in-band does nothing; `react` refuses non-system callers and unexpected
  logs; config validation; subscribe management is network-only; payment hooks; callback refuses
  non-proxy and wrong/zero RVM id; callback fails when it is not the guardian; admin and funding.
* `OrbitalMath.t.sol` — sqrt floor fuzz, √N, tick geometry, invariant at the equal point, exact-in
  solver lands on the surface, exact-out inverts exact-in, refusal paths, plane step, hook flags.
* `OrbitalToken.t.sol`, `Deploy.t.sol` — supply/transfer/no admin surface; `deploy(Config)` wires
  guardian and ownership at a mined address.

Tests read no environment variables and do not depend on the caller address; they pass in any order
and in parallel. The pinned floor suites (`Hook.protected.t.sol`, `Token.protected.t.sol`) were also run
locally against the real creation code (hook with constructor args naming non-existent token
addresses, flags 10376; token with decimals 18) and passed 9/9.

## Open items for the launch

* Verified Chainlink aggregator address and origin chain for the chosen basket coin.
* Confirm the Unichain Sepolia callback proxy address on the Reactive docs at deploy time.
* Multisig for `OWNER`; funding plan for both breaker contracts; monitoring/alerting on `Paused`.
* Independent adversarial review before any real funds.
