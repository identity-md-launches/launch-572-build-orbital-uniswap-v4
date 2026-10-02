// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BasketHarness, HookableERC20} from "../utils/BasketHarness.sol";
import {OrbitalHook} from "../../src/OrbitalHook.sol";

/// @notice Drives the hook while basket coins are randomly frozen (issuer pause) and thawed, the
/// regime the per-coin delivery fallback exists for: a withdrawal or fee payout of a frozen coin
/// becomes an ERC-6909 claim on the PoolManager owned by the LP, redeemable once the coin moves
/// again. The handler records every token that crossed the manager's boundary and every claim it
/// handed out, so the invariants can check that nothing is created, lost or stranded.
contract FrozenCoinHandler is Test {
    PoolManager public manager;
    PoolSwapTest public router;
    OrbitalHook public hook;
    HookableERC20[] public toks;
    address[] public lps;
    address public trader;
    uint256 public levelCount;

    // ---- ghost state -------------------------------------------------------------------------
    uint256[] public ghostNetIn; // per coin: tokens into the manager minus tokens out of it
    mapping(uint256 => mapping(address => uint256)) public ghostLpClaims; // coin ⇒ lp ⇒ claims held

    // ---- counters ----------------------------------------------------------------------------
    uint256 public claimDeliveries;
    uint256 public redemptions;
    uint256 public frozenDepositsRefused;
    uint256 public frozenSwapsRefused;
    uint256 public swapsOk;
    uint256 public withdrawalsOk;

    constructor(
        PoolManager _manager,
        PoolSwapTest _router,
        OrbitalHook _hook,
        HookableERC20[] memory _toks,
        address[] memory _lps,
        address _trader
    ) {
        manager = _manager;
        router = _router;
        hook = _hook;
        toks = _toks;
        lps = _lps;
        trader = _trader;
        levelCount = hook.levelCount();
        for (uint256 k = 0; k < _toks.length; k++) {
            ghostNetIn.push(0);
        }
    }

    // ---- helpers -----------------------------------------------------------------------------

    function n() public view returns (uint256) {
        return toks.length;
    }

    function claimId(uint256 k) public view returns (uint256) {
        return uint256(uint160(address(toks[k])));
    }

    function managerBalance(uint256 k) public view returns (uint256) {
        return toks[k].balanceOf(address(manager));
    }

    function hookClaims(uint256 k) public view returns (uint256) {
        return manager.balanceOf(address(hook), claimId(k));
    }

    function lpClaims(uint256 k, address lp) public view returns (uint256) {
        return manager.balanceOf(lp, claimId(k));
    }

    function anyFrozen() public view returns (bool) {
        for (uint256 k = 0; k < n(); k++) {
            if (toks[k].paused()) return true;
        }
        return false;
    }

    /// @dev Records what the manager holds after the test's own seed deposit as the starting flow.
    function seedNetIn() external {
        for (uint256 k = 0; k < n(); k++) {
            ghostNetIn[k] = managerBalance(k);
        }
    }

    function maxes() internal view returns (uint256[] memory m) {
        m = new uint256[](n());
        for (uint256 k = 0; k < n(); k++) {
            m[k] = type(uint256).max;
        }
    }

    function snapshot(address who) internal view returns (uint256[] memory bal, uint256[] memory claims) {
        bal = new uint256[](n());
        claims = new uint256[](n());
        for (uint256 k = 0; k < n(); k++) {
            bal[k] = toks[k].balanceOf(who);
            claims[k] = lpClaims(k, who);
        }
    }

    /// @dev After a payout to `who` of `amounts` (plus `fees`): a frozen coin arrived as claims,
    /// a liquid one as tokens, and the ghosts move accordingly.
    function settlePayout(
        address who,
        uint256[] memory balBefore,
        uint256[] memory claimsBefore,
        uint256[] memory amounts,
        uint256[] memory fees
    ) internal {
        for (uint256 k = 0; k < n(); k++) {
            uint256 total = amounts[k] + fees[k];
            uint256 gotTokens = toks[k].balanceOf(who) - balBefore[k];
            uint256 gotClaims = lpClaims(k, who) - claimsBefore[k];
            if (toks[k].paused()) {
                assertEq(gotTokens, 0, "frozen coin moved as tokens");
                assertEq(gotClaims, total, "frozen coin delivered as claims, in full");
                if (total > 0) claimDeliveries++;
            } else {
                assertEq(gotTokens, total, "liquid coin delivered as tokens, in full");
                assertEq(gotClaims, 0, "liquid coin delivered as claims");
            }
            ghostNetIn[k] -= gotTokens;
            ghostLpClaims[k][who] += gotClaims;
        }
    }

    // ---- actions -----------------------------------------------------------------------------

    function freeze(uint256 coinSeed, bool frozen) external {
        toks[coinSeed % n()].setPaused(frozen);
    }

    function deposit(uint256 lpSeed, uint256 levelSeed, uint256 radius) external {
        address lp = lps[lpSeed % lps.length];
        uint256 level = levelSeed % levelCount;
        radius = bound(radius, hook.MIN_RADIUS(), 2_000_000e18);
        uint256[] memory preview;
        try hook.previewDeposit(level, radius) returns (uint256[] memory p) {
            preview = p;
        } catch {
            return;
        }
        bool needsFrozen;
        for (uint256 k = 0; k < n(); k++) {
            if (preview[k] > 0 && toks[k].paused()) needsFrozen = true;
        }
        (uint256[] memory balBefore, uint256[] memory claimsBefore) = snapshot(lp);
        uint256[] memory fees = hook.pendingFees(level, lp);
        uint256 posBefore = hook.positions(level, lp);
        vm.prank(lp);
        try hook.deposit(level, radius, maxes()) returns (uint256[] memory amounts) {
            assertFalse(needsFrozen, "deposit pulled a frozen coin");
            // Pending fees were paid out first (as claims for a frozen coin), then the deposit pulled.
            for (uint256 k = 0; k < n(); k++) {
                assertEq(amounts[k], preview[k], "deposit != preview");
                uint256 gotClaims = lpClaims(k, lp) - claimsBefore[k];
                uint256 feeTokens;
                if (toks[k].paused()) {
                    assertEq(gotClaims, fees[k], "frozen fee delivered as claims");
                    if (fees[k] > 0) claimDeliveries++;
                } else {
                    assertEq(gotClaims, 0, "liquid fee delivered as claims");
                    feeTokens = fees[k];
                }
                assertEq(toks[k].balanceOf(lp) + amounts[k], balBefore[k] + feeTokens, "lp paid exactly the amounts");
                ghostNetIn[k] = ghostNetIn[k] + amounts[k] - feeTokens;
                ghostLpClaims[k][lp] += gotClaims;
            }
            assertEq(hook.positions(level, lp), posBefore + radius);
        } catch (bytes memory err) {
            assertTrue(needsFrozen, "deposit refused with every coin liquid");
            assertEq(bytes4(err), OrbitalHook.TransferFailed.selector, "frozen deposit reason");
            assertEq(hook.positions(level, lp), posBefore, "refused deposit changed the position");
            for (uint256 k = 0; k < n(); k++) {
                assertEq(toks[k].balanceOf(lp), balBefore[k], "refused deposit moved tokens");
                assertEq(lpClaims(k, lp), claimsBefore[k], "refused deposit moved claims");
            }
            frozenDepositsRefused++;
        }
    }

    function withdraw(uint256 lpSeed, uint256 levelSeed, bool full) external {
        address lp = lps[lpSeed % lps.length];
        uint256 level = levelSeed % levelCount;
        uint256 held = hook.positions(level, lp);
        if (held == 0) return;
        uint256 minR = hook.MIN_RADIUS();
        uint256 levelRadius = hook.level(level).radius;
        uint256 radius;
        if (full || held < 2 * minR) {
            if (levelRadius != held && levelRadius - held < minR) return;
            radius = held;
        } else {
            radius = held / 2; // leaves ≥ MIN_RADIUS in the position and in the tick
        }
        (uint256[] memory balBefore, uint256[] memory claimsBefore) = snapshot(lp);
        uint256[] memory fees = hook.pendingFees(level, lp);
        // Liveness: a frozen coin never blocks a withdrawal.
        vm.prank(lp);
        uint256[] memory amounts = hook.withdraw(level, radius, new uint256[](n()));
        settlePayout(lp, balBefore, claimsBefore, amounts, fees);
        assertEq(hook.positions(level, lp), held - radius);
        withdrawalsOk++;
    }

    function collectFees(uint256 lpSeed, uint256 levelSeed) external {
        address lp = lps[lpSeed % lps.length];
        uint256 level = levelSeed % levelCount;
        (uint256[] memory balBefore, uint256[] memory claimsBefore) = snapshot(lp);
        uint256[] memory fees = hook.pendingFees(level, lp);
        vm.prank(lp);
        uint256[] memory got = hook.collectFees(level);
        for (uint256 k = 0; k < n(); k++) {
            assertEq(got[k], fees[k], "collected != pending");
        }
        settlePayout(lp, balBefore, claimsBefore, new uint256[](n()), got);
    }

    function swapExactIn(uint256 iSeed, uint256 jSeed, uint256 amount) external {
        uint256 i = iSeed % n();
        uint256 j = (i + 1 + jSeed % (n() - 1)) % n();
        amount = bound(amount, 1, 500_000 * 10 ** toks[i].decimals());
        uint256 quoted;
        try hook.quoteExactInput(address(toks[i]), address(toks[j]), amount) returns (uint256 q) {
            quoted = q;
        } catch {
            return; // geometry refusal; the plain invariant suite covers those
        }
        bool frozenLeg = toks[i].paused() || (quoted > 0 && toks[j].paused());
        uint256[] memory x = hook.reserves();
        uint256 inBefore = toks[i].balanceOf(trader);
        uint256 outBefore = toks[j].balanceOf(trader);
        if (_routerSwap(i, j, amount)) {
            assertFalse(frozenLeg, "swap settled a frozen coin");
            uint256 paid = inBefore - toks[i].balanceOf(trader);
            uint256 got = toks[j].balanceOf(trader) - outBefore;
            assertEq(paid, amount);
            assertEq(got, quoted, "output == quote");
            ghostNetIn[i] += paid;
            ghostNetIn[j] -= got;
            swapsOk++;
        } else {
            assertTrue(frozenLeg, "swap refused with both legs liquid");
            // The hook's state changes were rolled back with the router's failed settlement.
            uint256[] memory xAfter = hook.reserves();
            for (uint256 k = 0; k < n(); k++) {
                assertEq(xAfter[k], x[k], "refused swap changed the reserves");
            }
            assertEq(toks[i].balanceOf(trader), inBefore);
            frozenSwapsRefused++;
        }
    }

    function _routerSwap(uint256 i, uint256 j, uint256 amount) internal returns (bool ok) {
        (address c0, address c1) = address(toks[i]) < address(toks[j])
            ? (address(toks[i]), address(toks[j]))
            : (address(toks[j]), address(toks[i]));
        bool z = c0 == address(toks[i]);
        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, 60, IHooks(address(hook)));
        vm.prank(trader);
        try router.swap(
            key,
            SwapParams(z, -int256(amount), z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function redeem(uint256 lpSeed, uint256 coinSeed, uint256 amountSeed) external {
        address lp = lps[lpSeed % lps.length];
        uint256 k = coinSeed % n();
        uint256 held = lpClaims(k, lp);
        if (held == 0) return;
        uint256 amount = bound(amountSeed, 1, held);
        uint256 balBefore = toks[k].balanceOf(lp);
        vm.startPrank(lp);
        manager.setOperator(address(hook), true);
        if (toks[k].paused()) {
            vm.expectRevert(OrbitalHook.TransferFailed.selector);
            hook.redeemClaims(address(toks[k]), amount, lp);
            vm.stopPrank();
            assertEq(lpClaims(k, lp), held, "failed redeem consumed claims");
            return;
        }
        hook.redeemClaims(address(toks[k]), amount, lp);
        vm.stopPrank();
        assertEq(toks[k].balanceOf(lp) - balBefore, amount, "redeemed exactly the claims handed in");
        assertEq(lpClaims(k, lp), held - amount);
        ghostNetIn[k] -= amount;
        ghostLpClaims[k][lp] -= amount;
        redemptions++;
    }
}

/// @notice Invariants for the frozen-coin regime: three coins (one with 6 decimals), two ticks,
/// two LPs, a trader, and a coin frozen or thawed at random between calls.
contract OrbitalFrozenCoinInvariantTest is StdInvariant, BasketHarness {
    FrozenCoinHandler handler;
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address trader = makeAddr("trader");

    function setUp() public {
        uint8[] memory decs = new uint8[](3);
        decs[0] = 18;
        decs[1] = 18;
        decs[2] = 6;
        uint256[] memory ks = new uint256[](2);
        ks[0] = 0.74e18;
        ks[1] = 1.15e18;
        deployBasket(decs, ks, 400);
        fund(lp1);
        fund(lp2);
        fund(trader);
        address[] memory lps = new address[](2);
        lps[0] = lp1;
        lps[1] = lp2;
        handler = new FrozenCoinHandler(manager, router, hook, toks, lps, trader);
        // Seeded before any coin can freeze, as a launch would be.
        deposit(lp1, 1, 1_000_000e18);
        handler.seedNetIn();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = FrozenCoinHandler.freeze.selector;
        selectors[1] = FrozenCoinHandler.deposit.selector;
        selectors[2] = FrozenCoinHandler.withdraw.selector;
        selectors[3] = FrozenCoinHandler.collectFees.selector;
        selectors[4] = FrozenCoinHandler.swapExactIn.selector;
        selectors[5] = FrozenCoinHandler.redeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function pendingFeesAll(uint256 k) internal view returns (uint256 total) {
        for (uint256 a = 0; a < 2; a++) {
            for (uint256 l = 0; l < hook.levelCount(); l++) {
                total += hook.pendingFees(l, handler.lps(a))[k];
            }
        }
    }

    /// @notice Every token in the manager is spoken for: the hook's claims plus the claims it handed
    /// to LPs for frozen coins, and that total is exactly the netted flow across the boundary.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_claimsAccountForEveryToken() public view {
        for (uint256 k = 0; k < 3; k++) {
            uint256 lpClaims = handler.lpClaims(k, lp1) + handler.lpClaims(k, lp2);
            assertEq(handler.managerBalance(k), handler.hookClaims(k) + lpClaims, "manager balance != claims");
            assertEq(handler.managerBalance(k), handler.ghostNetIn(k), "manager balance != netted flows");
            assertEq(handler.lpClaims(k, lp1), handler.ghostLpClaims(k, lp1), "lp1 claims != delivered minus redeemed");
            assertEq(handler.lpClaims(k, lp2), handler.ghostLpClaims(k, lp2), "lp2 claims != delivered minus redeemed");
            assertEq(manager.balanceOf(address(router), handler.claimId(k)), 0, "router holds claims");
        }
    }

    /// @notice Claims handed to LPs never dilute the hook: what the hook still holds covers the
    /// real reserves it reports plus every fee it still owes.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_hookStaysSolventWhileCoinsFreeze() public view {
        uint256[] memory real = hook.realReserves();
        uint256 slack = handler.withdrawalsOk(); // one WAD-wei of floor rounding per withdrawal
        for (uint256 k = 0; k < 3; k++) {
            uint256 backing = handler.hookClaims(k) * hook.scale(k);
            assertGe(backing + slack, real[k] + pendingFeesAll(k) * hook.scale(k), "hook claims under-back the pool");
        }
    }

    /// @notice Positions and radii add up regardless of how coins were delivered.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_radiusAccountingUnderFreezes() public view {
        uint256 sumLevels;
        for (uint256 l = 0; l < hook.levelCount(); l++) {
            uint256 perLevel = hook.positions(l, lp1) + hook.positions(l, lp2);
            assertEq(perLevel, hook.level(l).radius, "level radius != positions");
            sumLevels += perLevel;
        }
        assertEq(hook.totalRadius(), sumLevels);
    }
}
