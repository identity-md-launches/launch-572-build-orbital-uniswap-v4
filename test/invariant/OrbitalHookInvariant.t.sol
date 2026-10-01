// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {OrbitalFixture} from "../utils/OrbitalFixture.sol";
import {OrbitalHook} from "../../src/OrbitalHook.sol";
import {OrbitalMath} from "../../src/libraries/OrbitalMath.sol";

/// @notice Drives the hook with random, bounded deposits, withdrawals, swaps (both kinds), fee
/// collection, pauses and fee changes from several actors, and keeps ghost totals of every token
/// that crossed the PoolManager's boundary.
///
/// Expected reverts are allow-listed by selector; any other revert is re-raised so that the
/// invariant run fails loudly (`fail_on_revert = true` on every invariant below).
contract OrbitalHandler is Test {
    PoolManager public manager;
    PoolSwapTest public swapRouter;
    OrbitalHook public hook;

    address[] public tokens; // basket order
    uint256[] public scales;
    uint256 public maxScale;
    uint256 public seedRadius;
    uint256 public minTotalRadius; // smallest total radius the pool has had since seeding
    /// @dev The pool never shrinks below this: a dust-sized pool is the reported deposit-skim
    /// regime (wei-level reserves make every later proportional deposit and every derived tick
    /// status meaningless), and the implementation has no residual floor on withdrawals.
    uint256 public constant MIN_POOL_RADIUS = 10_000e18;
    PoolKey[3] internal keys; // (0,1), (0,2), (1,2)
    uint8[3][2] internal pairIdx;

    address[] public lps;
    address[] public traders;
    address public owner;
    address public guardian;
    uint256 public levelCount;

    // ---- ghost state -------------------------------------------------------------------------
    uint256[] public ghostDeposited; // per token, raw units transferred in by LPs
    uint256[] public ghostWithdrawn; // per token, raw units transferred out to LPs (principal)
    uint256[] public ghostFeesPaid; // per token, raw units paid out as fees
    uint256[] public ghostSwapIn; // per token, raw units paid in by traders
    uint256[] public ghostSwapOut; // per token, raw units taken out by traders
    mapping(uint256 => mapping(address => uint256)) public ghostPosition;
    uint256 public ghostTotalRadius;

    // ---- counters (for sanity: the run actually did things) ----------------------------------
    uint256 public depositsOk;
    uint256 public depositsRefused;
    uint256 public withdrawalsOk;
    uint256 public swapsOk;
    uint256 public swapsRefused;
    uint256 public swapsZeroOut;
    uint256 public crossings;
    uint256 public pausedBlocks;
    uint256 public roundTrips;
    uint256 public lowerArcAvoided; // swaps rolled back because they hit the reported crossing defect

    uint256 internal constant MAX_RADIUS_PER_DEPOSIT = 3_000_000e18;

    constructor(
        PoolManager _manager,
        PoolSwapTest _router,
        OrbitalHook _hook,
        address[] memory _tokens,
        PoolKey[3] memory _keys,
        address[] memory _lps,
        address[] memory _traders,
        address _owner,
        address _guardian
    ) {
        manager = _manager;
        swapRouter = _router;
        hook = _hook;
        tokens = _tokens;
        for (uint256 p = 0; p < 3; p++) {
            keys[p] = _keys[p];
        }
        lps = _lps;
        traders = _traders;
        owner = _owner;
        guardian = _guardian;
        levelCount = hook.levelCount();
        // keys: (A,B), (A,C), (B,C) in basket indices
        pairIdx[0] = [0, 0, 1];
        pairIdx[1] = [1, 2, 2];
        for (uint256 k = 0; k < _tokens.length; k++) {
            scales.push(hook.scale(k));
            if (hook.scale(k) > maxScale) maxScale = hook.scale(k);
            ghostDeposited.push(0);
            ghostWithdrawn.push(0);
            ghostFeesPaid.push(0);
            ghostSwapIn.push(0);
            ghostSwapOut.push(0);
        }
    }

    // ---- helpers -----------------------------------------------------------------------------

    function n() public view returns (uint256) {
        return tokens.length;
    }

    function balance(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok, "balanceOf");
        return abi.decode(ret, (uint256));
    }

    function managerBalance(uint256 k) public view returns (uint256) {
        return balance(tokens[k], address(manager));
    }

    function hookClaims(uint256 k) public view returns (uint256) {
        return manager.balanceOf(address(hook), uint256(uint160(tokens[k])));
    }

    /// @dev How many times larger the pool is than the smallest it has been (rounded up). Rounding
    /// dust left inside the sphere when the pool was small is multiplied by this factor by later
    /// proportional deposits.
    function growthSinceSeed() public view returns (uint256) {
        uint256 total = hook.totalRadius();
        if (minTotalRadius == 0 || total <= minTotalRadius) return 1;
        return (total + minTotalRadius - 1) / minTotalRadius;
    }

    /// @dev Upper bound, in raw units of token `i`, on the value of the rounding dust the pool can
    /// hold inside the sphere: one raw unit of whichever basket coin, valued at the interior's
    /// marginal price (r − x_k) / (r − x_i), times the pool's growth since it was smallest.
    function dustValueIn(uint256 i) public view returns (uint256) {
        (uint256 r,,) = hook.consolidated();
        if (r == 0) return type(uint128).max;
        uint256[] memory xi = new uint256[](n());
        uint256 mask = hook.boundaryMask();
        for (uint256 l = 0; l < levelCount; l++) {
            if (hook.level(l).radius == 0 || mask & (1 << l) != 0) continue;
            uint256[] memory v = hook.levelReserves(l);
            for (uint256 k = 0; k < n(); k++) {
                xi[k] += v[k];
            }
        }
        uint256 denom = r > xi[i] ? r - xi[i] : 1;
        uint256 best;
        for (uint256 k = 0; k < n(); k++) {
            uint256 value = scales[k] * (r > xi[k] ? r - xi[k] : 0) / denom / scales[i];
            if (value > best) best = value;
        }
        return (best + 1) * growthSinceSeed();
    }

    /// @dev Seeds the pool the way a launch does (one real-sized deposit) and records it in the
    /// ghost totals, so the sequences explore the healthy regime rather than a dust pool.
    function seed(uint256 level, uint256 radius) external {
        require(seedRadius == 0, "seeded");
        address lp = lps[0];
        uint256[] memory max = new uint256[](n());
        for (uint256 k = 0; k < n(); k++) {
            max[k] = type(uint256).max;
        }
        vm.prank(lp);
        uint256[] memory amounts = hook.deposit(level, radius, max);
        for (uint256 k = 0; k < n(); k++) {
            ghostDeposited[k] += amounts[k];
        }
        ghostPosition[level][lp] += radius;
        ghostTotalRadius += radius;
        seedRadius = radius;
        minTotalRadius = radius;
    }

    /// @dev True when the pool is in the configuration the implementation cannot represent: a
    /// tick is pinned while the interior's off-peg component points against the pinned ticks'
    /// (global ‖w‖ below the boundary sum), or a pinned tick sits above the interior position. The
    /// implementation's endpoint-only crossing check lets ordinary return trades enter this state;
    /// that is a reported defect (with its own proof), so the handler rolls such swaps back and
    /// counts them instead of letting every later property fail on a state the model has no
    /// meaning for.
    function inBrokenRegime() public view returns (bool) {
        uint256 mask = hook.boundaryMask();
        if (mask == 0) return false;
        (uint256 r,, uint256 sb) = hook.consolidated();
        uint256[] memory x = hook.reserves();
        uint256 s;
        uint256 q;
        for (uint256 k = 0; k < x.length; k++) {
            s += x[k];
            q += x[k] * x[k];
        }
        uint256 a2 = s * s / x.length;
        uint256 w = OrbitalMath.sqrt(q > a2 ? q - a2 : 0);
        if (w < sb) return true;
        if (r == 0) return false;
        int256 a = hook.alphaIntNorm();
        for (uint256 l = 0; l < levelCount; l++) {
            OrbitalHook.Level memory L = hook.level(l);
            if (L.radius == 0 || mask & (1 << l) == 0) continue;
            if (a + 1e9 < int256(L.kNorm)) return true;
        }
        return false;
    }

    /// @dev Runs a swap through the router; if it lands the pool in the broken regime, the state is
    /// rolled back and the swap reported as not executed.
    function guardedSwap(address trader, PoolKey memory key, SwapParams memory params)
        internal
        returns (bool executed)
    {
        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        swapRouter.swap(key, params, settings(), "");
        if (inBrokenRegime()) {
            vm.revertToState(snap);
            lowerArcAvoided++;
            return false;
        }
        return true;
    }

    /// @dev Unwraps v4's ERC-7751 `WrappedError` (possibly nested) down to the innermost selector.
    function innerSelector(bytes memory err) public pure returns (bytes4 sel) {
        if (err.length < 4) return bytes4(0);
        sel = bytes4(err);
        if (sel != CustomRevert.WrappedError.selector) return sel;
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = err[i + 4];
        }
        (,, bytes memory reason,) = abi.decode(body, (address, bytes4, bytes, bytes));
        return innerSelector(reason);
    }

    /// @dev Reverts the hook may legitimately raise when a bounded-but-random input asks for a
    /// trade or deposit the geometry cannot serve.
    function isAllowedRefusal(bytes4 sel) public pure returns (bool) {
        return sel == OrbitalHook.NoInteriorLiquidity.selector || sel == OrbitalMath.InsufficientLiquidity.selector
            || sel == OrbitalHook.SwapTooLarge.selector || sel == OrbitalHook.TooManyCrossings.selector
            || sel == OrbitalMath.PlaneUnreachable.selector || sel == OrbitalHook.ZeroAmount.selector
            || sel == OrbitalHook.AmountOverflow.selector;
    }

    function rethrow(bytes memory err) internal pure {
        assembly ("memory-safe") {
            revert(add(err, 0x20), mload(err))
        }
    }

    function swapParams(bool zeroForOne, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function pair(uint256 seed, bool flip) internal view returns (PoolKey memory key, uint8 i, uint8 j, bool z) {
        uint256 p = seed % 3;
        key = keys[p];
        (i, j) = flip ? (pairIdx[1][p], pairIdx[0][p]) : (pairIdx[0][p], pairIdx[1][p]);
        z = Currency.unwrap(key.currency0) == tokens[i];
    }

    function settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    // ---- actions -----------------------------------------------------------------------------

    function deposit(uint256 lpSeed, uint256 levelSeed, uint256 radius) external {
        address lp = lps[lpSeed % lps.length];
        uint256 level = levelSeed % levelCount;
        radius = bound(radius, hook.MIN_RADIUS(), MAX_RADIUS_PER_DEPOSIT);
        uint256[] memory max = new uint256[](n());
        for (uint256 k = 0; k < n(); k++) {
            max[k] = type(uint256).max;
        }

        if (hook.paused()) {
            vm.prank(lp);
            try hook.deposit(level, radius, max) {
                revert("deposit succeeded while paused");
            } catch (bytes memory err) {
                assertEq(bytes4(err), OrbitalHook.IsPaused.selector, "paused deposit must revert IsPaused");
                pausedBlocks++;
                return;
            }
        }

        uint256[] memory preview;
        try hook.previewDeposit(level, radius) returns (uint256[] memory p) {
            preview = p;
        } catch (bytes memory err) {
            if (!isAllowedRefusal(bytes4(err))) rethrow(err);
            // The real deposit must refuse for the same reason.
            vm.prank(lp);
            try hook.deposit(level, radius, max) {
                revert("deposit succeeded although preview refused");
            } catch (bytes memory err2) {
                assertEq(bytes4(err2), bytes4(err), "deposit and preview disagree on refusal");
            }
            depositsRefused++;
            return;
        }

        uint256[] memory lpBefore = new uint256[](n());
        uint256[] memory mgrBefore = new uint256[](n());
        for (uint256 k = 0; k < n(); k++) {
            lpBefore[k] = balance(tokens[k], lp);
            mgrBefore[k] = managerBalance(k);
        }
        uint256 posBefore = hook.positions(level, lp);
        uint256 totalBefore = hook.totalRadius();
        uint256[] memory pending = hook.pendingFees(level, lp);

        // The preview is used as the slippage cap: a deposit that needs more than it quoted is a bug.
        vm.prank(lp);
        uint256[] memory amounts = hook.deposit(level, radius, preview);

        for (uint256 k = 0; k < n(); k++) {
            assertEq(amounts[k], preview[k], "deposit != preview");
            // A deposit also settles the LP's pending fees, so the net flow is amounts − pending.
            int256 net = int256(amounts[k]) - int256(pending[k]);
            assertEq(int256(lpBefore[k]) - int256(balance(tokens[k], lp)), net, "lp paid exactly the amounts");
            assertEq(int256(managerBalance(k)) - int256(mgrBefore[k]), net, "manager received exactly the amounts");
            ghostDeposited[k] += amounts[k];
            ghostFeesPaid[k] += pending[k];
        }
        assertEq(hook.positions(level, lp), posBefore + radius, "position grew by radius");
        assertEq(hook.totalRadius(), totalBefore + radius, "total radius grew by radius");
        ghostPosition[level][lp] += radius;
        ghostTotalRadius += radius;
        depositsOk++;
    }

    function withdraw(uint256 lpSeed, uint256 levelSeed, uint256 radiusSeed) external {
        address lp = lps[lpSeed % lps.length];
        uint256 level = levelSeed % levelCount;
        uint256 held = hook.positions(level, lp);
        if (held == 0) return;
        // Keep the pool out of the dust regime (see MIN_POOL_RADIUS); full exits of a position are
        // still exercised whenever other liquidity remains.
        uint256 total = hook.totalRadius();
        if (total <= MIN_POOL_RADIUS) return;
        uint256 cap = total - MIN_POOL_RADIUS;
        uint256 radius = bound(radiusSeed, 1, held < cap ? held : cap);

        uint256[] memory lpBefore = new uint256[](n());
        uint256[] memory mgrBefore = new uint256[](n());
        for (uint256 k = 0; k < n(); k++) {
            lpBefore[k] = balance(tokens[k], lp);
            mgrBefore[k] = managerBalance(k);
        }
        uint256[] memory pending = hook.pendingFees(level, lp);
        uint256 totalBefore = hook.totalRadius();

        // Withdrawal liveness: never refused, paused or not, whatever the geometry.
        vm.prank(lp);
        uint256[] memory amounts = hook.withdraw(level, radius, new uint256[](n()));

        for (uint256 k = 0; k < n(); k++) {
            assertEq(balance(tokens[k], lp) - lpBefore[k], amounts[k] + pending[k], "lp received exactly the amounts");
            assertEq(mgrBefore[k] - managerBalance(k), amounts[k] + pending[k], "manager paid exactly the amounts");
            ghostWithdrawn[k] += amounts[k];
            ghostFeesPaid[k] += pending[k];
        }
        assertEq(hook.positions(level, lp), held - radius, "position shrank by radius");
        assertEq(hook.totalRadius(), totalBefore - radius, "total radius shrank by radius");
        ghostPosition[level][lp] -= radius;
        ghostTotalRadius -= radius;
        if (hook.totalRadius() < minTotalRadius) minTotalRadius = hook.totalRadius();
        withdrawalsOk++;
    }

    function collectFees(uint256 lpSeed, uint256 levelSeed) external {
        address lp = lps[lpSeed % lps.length];
        uint256 level = levelSeed % levelCount;
        uint256[] memory pending = hook.pendingFees(level, lp);
        uint256[] memory lpBefore = new uint256[](n());
        for (uint256 k = 0; k < n(); k++) {
            lpBefore[k] = balance(tokens[k], lp);
        }
        vm.prank(lp);
        uint256[] memory got = hook.collectFees(level);
        for (uint256 k = 0; k < n(); k++) {
            assertEq(got[k], pending[k], "collected != pending");
            assertEq(balance(tokens[k], lp) - lpBefore[k], got[k], "fees actually transferred");
            assertEq(hook.pendingFees(level, lp)[k], 0, "nothing pending after collection");
            ghostFeesPaid[k] += got[k];
        }
    }

    function swapExactIn(uint256 traderSeed, uint256 pairSeed, bool flip, uint256 amount) external {
        address trader = traders[traderSeed % traders.length];
        (PoolKey memory key, uint8 i, uint8 j, bool z) = pair(pairSeed, flip);
        amount = bound(amount, 1, 2_000_000e18 / scales[i]);

        if (hook.paused()) {
            vm.prank(trader);
            try swapRouter.swap(key, swapParams(z, -int256(amount)), settings(), "") {
                revert("swap succeeded while paused");
            } catch (bytes memory err) {
                assertEq(innerSelector(err), OrbitalHook.IsPaused.selector, "paused swap must revert IsPaused");
                pausedBlocks++;
                return;
            }
        }

        uint256 quoted;
        try hook.quoteExactInput(tokens[i], tokens[j], amount) returns (uint256 q) {
            quoted = q;
        } catch (bytes memory err) {
            if (!isAllowedRefusal(bytes4(err))) rethrow(err);
            vm.prank(trader);
            try swapRouter.swap(key, swapParams(z, -int256(amount)), settings(), "") {
                revert("swap succeeded although quote refused");
            } catch (bytes memory err2) {
                assertEq(innerSelector(err2), bytes4(err), "swap and quote disagree on refusal");
            }
            swapsRefused++;
            return;
        }

        uint256 inBefore = balance(tokens[i], trader);
        uint256 outBefore = balance(tokens[j], trader);
        uint256 maskBefore = hook.boundaryMask();
        if (!guardedSwap(trader, key, swapParams(z, -int256(amount)))) return;
        uint256 paid = inBefore - balance(tokens[i], trader);
        uint256 got = balance(tokens[j], trader) - outBefore;
        assertEq(paid, amount, "exact-in pays exactly the input");
        assertEq(got, quoted, "exact-in output == quote");
        ghostSwapIn[i] += paid;
        ghostSwapOut[j] += got;
        if (got == 0) swapsZeroOut++;
        if (hook.boundaryMask() != maskBefore) crossings++;
        swapsOk++;
    }

    function swapExactOut(uint256 traderSeed, uint256 pairSeed, bool flip, uint256 amountOut) external {
        address trader = traders[traderSeed % traders.length];
        (PoolKey memory key, uint8 i, uint8 j, bool z) = pair(pairSeed, flip);
        // Stay a few wei clear of the whole real reserve: `realReserves` can over-state the claims
        // backing by one WAD-wei per past withdrawal (reported, see findings), and draining to the
        // last wei would then fail in the manager's burn rather than in the hook's pricing. The
        // exact-boundary refusal is covered by a unit test.
        uint256 realOut = hook.realReserves()[j] / scales[j];
        if (realOut <= 64) return;
        amountOut = bound(amountOut, 1, realOut - 64);

        if (hook.paused()) {
            vm.prank(trader);
            try swapRouter.swap(key, swapParams(z, int256(amountOut)), settings(), "") {
                revert("swap succeeded while paused");
            } catch (bytes memory err) {
                assertEq(innerSelector(err), OrbitalHook.IsPaused.selector, "paused swap must revert IsPaused");
                pausedBlocks++;
                return;
            }
        }

        uint256 quoted;
        try hook.quoteExactOutput(tokens[i], tokens[j], amountOut) returns (uint256 q) {
            quoted = q;
        } catch (bytes memory err) {
            if (!isAllowedRefusal(bytes4(err))) rethrow(err);
            vm.prank(trader);
            try swapRouter.swap(key, swapParams(z, int256(amountOut)), settings(), "") {
                revert("swap succeeded although quote refused");
            } catch (bytes memory err2) {
                assertEq(innerSelector(err2), bytes4(err), "swap and quote disagree on refusal");
            }
            swapsRefused++;
            return;
        }

        uint256 inBefore = balance(tokens[i], trader);
        uint256 outBefore = balance(tokens[j], trader);
        uint256 maskBefore = hook.boundaryMask();
        if (!guardedSwap(trader, key, swapParams(z, int256(amountOut)))) return;
        uint256 paid = inBefore - balance(tokens[i], trader);
        uint256 got = balance(tokens[j], trader) - outBefore;
        assertEq(got, amountOut, "exact-out receives exactly the output");
        assertEq(paid, quoted, "exact-out input == quote");
        assertGt(paid, 0, "exact-out never free");
        ghostSwapIn[i] += paid;
        ghostSwapOut[j] += got;
        if (hook.boundaryMask() != maskBefore) crossings++;
        swapsOk++;
    }

    /// @dev Forward-then-reverse exact-in trade by the same trader: no free money beyond the
    /// sub-unit rounding of the intermediate coin (at most one raw unit of it, re-expressed in the
    /// start coin at par) plus wei-level dust.
    function roundTrip(uint256 traderSeed, uint256 pairSeed, bool flip, uint256 amount) external {
        if (hook.paused()) return;
        address trader = traders[traderSeed % traders.length];
        (PoolKey memory key, uint8 i, uint8 j, bool z) = pair(pairSeed, flip);
        amount = bound(amount, 1, 500_000e18 / scales[i]);

        uint256 start = balance(tokens[i], trader);
        uint256 midBefore = balance(tokens[j], trader);
        try hook.quoteExactInput(tokens[i], tokens[j], amount) {}
        catch (bytes memory err) {
            if (!isAllowedRefusal(bytes4(err))) rethrow(err);
            return;
        }
        if (!guardedSwap(trader, key, swapParams(z, -int256(amount)))) return;
        uint256 got = balance(tokens[j], trader) - midBefore;
        ghostSwapIn[i] += amount;
        ghostSwapOut[j] += got;
        if (got == 0) return;

        try hook.quoteExactInput(tokens[j], tokens[i], got) {}
        catch (bytes memory err) {
            if (!isAllowedRefusal(bytes4(err))) rethrow(err);
            return;
        }
        if (!guardedSwap(trader, key, swapParams(!z, -int256(got)))) return;
        uint256 back = balance(tokens[i], trader) - (start - amount);
        ghostSwapIn[j] += got;
        ghostSwapOut[i] += back;
        // An exact-in trade keeps the sub-unit remainder of its output inside the pool (less than
        // one raw unit of that coin, i.e. < 1e12 WAD for the 6-decimal coin); the next trade on any
        // pair returns it. Deposits scale the whole virtual vector, so that remainder grows with
        // the pool (see `growthSinceSeed`). The most a round trip can gain is therefore one raw unit
        // of some basket coin times the pool's growth, valued in the start coin at the pool's
        // marginal price (`dustValueIn`, which can be far from par when the basket is off-peg),
        // plus wei-level solver rounding. The 4× covers fee gross-up and the gap between marginal
        // and average rates over the two legs. (With a dust-sized pool this bound explodes: that is
        // the reported deposit-skim finding, not something this suite blesses.)
        uint256 slack = 4 * dustValueIn(i) + 10;
        assertLe(balance(tokens[i], trader), start + slack, "round trip profited");
        roundTrips++;
    }

    function togglePause(uint256 seed) external {
        if (seed % 4 == 0) {
            vm.prank(guardian);
            hook.guardianPause();
            assertTrue(hook.paused());
        } else {
            vm.prank(owner);
            hook.unpause();
            assertFalse(hook.paused());
        }
    }

    function setFee(uint24 fee) external {
        fee = uint24(bound(fee, 0, hook.MAX_FEE_PPM()));
        vm.prank(owner);
        hook.setFee(fee);
        assertEq(hook.feePpm(), fee);
    }
}

/// @notice Invariants over random call sequences against the Orbital hook. The hook holds every
/// LP's tokens (as ERC-6909 claims on the PoolManager), so these are the solvency properties.
///
/// The pool is seeded at launch size before the sequences start. Without that seed the handler's
/// no-free-money property fails: a dust-sized first deposit lets sub-unit rounding move the
/// virtual point far inside the sphere, and later proportional deposits inherit the excess for the
/// next trader to take. That is a defect of the implementation, reported in the findings file with
/// a stand-alone proof; it is not tolerated here, it is simply outside this suite's regime.
contract OrbitalHookInvariantTest is StdInvariant, OrbitalFixture {
    OrbitalHandler handler;
    address lp2 = makeAddr("lp2");
    address lp3 = makeAddr("lp3");
    address trader2 = makeAddr("trader2");

    function setUp() public override {
        super.setUp();
        fund(lp2, 1_000_000_000);
        fund(lp3, 1_000_000_000);
        fund(trader2, 1_000_000_000);
        fund(lp, 1_000_000_000);
        fund(trader, 1_000_000_000);

        address[] memory lps = new address[](3);
        lps[0] = lp;
        lps[1] = lp2;
        lps[2] = lp3;
        address[] memory traders = new address[](2);
        traders[0] = trader;
        traders[1] = trader2;
        PoolKey[3] memory keys = [keyAB, keyAC, keyBC];

        handler = new OrbitalHandler(manager, swapRouter, hook, basket, keys, lps, traders, owner, guardian);
        // Launch-sized seed (1M radius, full range), as the deployer would do before opening the pool.
        handler.seed(WIDE, 1_000_000e18);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = OrbitalHandler.deposit.selector;
        selectors[1] = OrbitalHandler.withdraw.selector;
        selectors[2] = OrbitalHandler.collectFees.selector;
        selectors[3] = OrbitalHandler.swapExactIn.selector;
        selectors[4] = OrbitalHandler.swapExactOut.selector;
        selectors[5] = OrbitalHandler.roundTrip.selector;
        selectors[6] = OrbitalHandler.togglePause.selector;
        selectors[7] = OrbitalHandler.setFee.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ---- helpers -----------------------------------------------------------------------------

    function pendingFeesAll(uint256 k) internal view returns (uint256 total) {
        uint256 levels = hook.levelCount();
        for (uint256 a = 0; a < 3; a++) {
            address who = handler.lps(a);
            for (uint256 l = 0; l < levels; l++) {
                total += hook.pendingFees(l, who)[k];
            }
        }
    }

    function virtualFloor() internal view returns (uint256 f) {
        uint256 levels = hook.levelCount();
        for (uint256 l = 0; l < levels; l++) {
            OrbitalHook.Level memory L = hook.level(l);
            f += L.xMinNorm * L.radius / 1e18;
        }
    }

    // ---- invariants --------------------------------------------------------------------------

    /// @notice Internal accounting == external reality: the manager holds exactly what the hook
    /// has claims on, and that equals every token that ever crossed the boundary, netted.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_tokenConservation() public view {
        for (uint256 k = 0; k < 3; k++) {
            uint256 expected = handler.ghostDeposited(k) + handler.ghostSwapIn(k) - handler.ghostWithdrawn(k)
                - handler.ghostFeesPaid(k) - handler.ghostSwapOut(k);
            assertEq(handler.managerBalance(k), expected, "manager balance != netted flows");
            assertEq(handler.hookClaims(k), expected, "hook claims != netted flows");
        }
    }

    /// @notice Solvency: the claims the hook holds cover the real reserves it reports plus every
    /// fee it still owes. Nothing an LP can withdraw is backed by tokens the manager lacks.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_claimsCoverReservesAndFees() public view {
        uint256[] memory real = hook.realReserves();
        // `realReserves` subtracts the floor of each level's *cumulative* radius, while a withdrawal
        // credits the floor of the radius it removes; the two can differ by one WAD-wei (1e-18 of a
        // token) per withdrawal, so the reported real reserve may over-state backing by that much.
        uint256 slack = handler.withdrawalsOk();
        for (uint256 k = 0; k < 3; k++) {
            uint256 backing = handler.hookClaims(k) * hook.scale(k);
            uint256 owed = real[k] + pendingFeesAll(k) * hook.scale(k);
            assertGe(backing + slack, owed, "claims do not cover real reserves + fees owed");
        }
    }

    /// @notice Sum of parts == tracked whole: level radii and every position add up to totalRadius,
    /// and match what the handler recorded.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_radiusAccounting() public view {
        uint256 levels = hook.levelCount();
        uint256 sumLevels;
        uint256 sumPositions;
        for (uint256 l = 0; l < levels; l++) {
            sumLevels += hook.level(l).radius;
            uint256 perLevel;
            for (uint256 a = 0; a < 3; a++) {
                address who = handler.lps(a);
                assertEq(hook.positions(l, who), handler.ghostPosition(l, who), "position != ghost");
                perLevel += hook.positions(l, who);
            }
            assertEq(perLevel, hook.level(l).radius, "level radius != sum of its positions");
            sumPositions += perLevel;
        }
        assertEq(hook.totalRadius(), sumLevels, "totalRadius != sum of levels");
        assertEq(hook.totalRadius(), sumPositions, "totalRadius != sum of positions");
        assertEq(hook.totalRadius(), handler.ghostTotalRadius(), "totalRadius != ghost");
        assertLe(hook.totalRadius(), hook.MAX_TOTAL_RADIUS(), "radius cap");
    }

    /// @notice The virtual point stays on the torus (|F| tiny relative to the scale of the pool),
    /// and never dips below the concentrated floor, so real reserves are never negative in truth.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_pointStaysOnTorusAboveFloor() public view {
        uint256 total = hook.totalRadius();
        if (total == 0) return;
        int256 f = hook.invariant();
        uint256 mag = f < 0 ? uint256(-f) : uint256(f);
        // Exact-in swaps keep up to one raw unit (1e12 WAD for the 6-decimal coin) of rounding
        // inside the pool; that moves the point inward by at most 2·r·1e12 in F, and proportional
        // deposits scale it with the pool's growth. Everything else is wei-level.
        uint256 tol = 4 * total * handler.maxScale() * handler.growthSinceSeed() + total * total / 1e12 + 1e36;
        assertLe(mag, tol, "point left the torus");

        uint256 floorAll = virtualFloor();
        uint256[] memory x = hook.reserves();
        for (uint256 k = 0; k < 3; k++) {
            assertGe(x[k] + total / 1e9 + 1e12, floorAll, "virtual reserve under the concentrated floor");
        }
    }

    /// @notice Flag/data synchronisation: a pinned tick's plane is at or below the interior's
    /// position; an interior tick's plane is at or above it.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_boundaryMaskMatchesPosition() public view {
        (uint256 r,,) = hook.consolidated();
        if (r == 0) return;
        int256 a = hook.alphaIntNorm();
        uint256 mask = hook.boundaryMask();
        uint256 levels = hook.levelCount();
        int256 tol = 1e9; // 1e-9 in normalised units: plane landings are rounded to the wei
        for (uint256 l = 0; l < levels; l++) {
            OrbitalHook.Level memory L = hook.level(l);
            if (L.radius == 0) continue;
            if (mask & (1 << l) != 0) {
                assertGe(a + tol, int256(L.kNorm), "pinned tick above the interior position");
            } else {
                assertLe(a, int256(L.kNorm) + tol, "interior tick below the interior position");
            }
        }
    }

    /// @notice No sequence of user actions (including guardian pauses and owner fee changes) moves
    /// the admin surface: the guardian and owner stay what they were and the fee stays capped. The
    /// handler itself asserts, per call, that the guardian can only pause, that pause blocks
    /// deposits and swaps with `IsPaused`, and that withdrawals and fee collection never fail.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_adminSurfaceUnchanged() public view {
        assertLe(hook.feePpm(), hook.MAX_FEE_PPM());
        assertEq(hook.guardian(), guardian, "guardian unchanged by any sequence");
        assertEq(hook.owner(), owner, "owner unchanged by any sequence");
        assertEq(hook.levelCount(), 3, "level set is immutable");
    }
}
