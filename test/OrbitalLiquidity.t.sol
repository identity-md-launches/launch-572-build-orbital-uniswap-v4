// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BasketHarness, HookableERC20} from "./utils/BasketHarness.sol";
import {OrbitalHook} from "../src/OrbitalHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Deposit pricing against a dusty pool, the radius floor, and a clean restart.
contract OrbitalDustPoolTest is BasketHarness {
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");

    function setUp() public {
        uint8[] memory decs = new uint8[](2);
        decs[0] = 18;
        decs[1] = 6;
        uint256[] memory ks = new uint256[](1);
        ks[0] = 0.7e18; // ~full range for N = 2 (kMax = 0.7071e18)
        deployBasket(decs, ks, 400);
        fund(attacker);
        fund(victim);
    }

    /// A pool opened at MIN_RADIUS whose point is pushed inside the sphere by a zero-output swap
    /// (the input is kept, nothing leaves) must not make the next depositor copy that skew: the
    /// deposit is priced on the sphere, so the skimmable excess stays the dust that was donated.
    function test_dustPoolDoesNotSkimLaterDepositors() public {
        uint256 minRadius = hook.MIN_RADIUS();
        vm.prank(attacker);
        uint256[] memory paid = hook.deposit(0, minRadius, maxes());
        assertGt(paid[0], 0);
        uint256 c0 = toks[1].balanceOf(attacker);
        swap(attacker, address(toks[0]), address(toks[1]), -int256(5e7)); // donation: 0 raw units out
        assertEq(toks[1].balanceOf(attacker), c0, "no output");
        assertLt(hook.invariant(), 0, "point inside the sphere");

        uint256[] memory want = hook.previewDeposit(0, 1e24);
        vm.prank(victim);
        uint256[] memory vpaid = hook.deposit(0, 1e24, want);
        assertEq(vpaid[0], want[0]);
        // The honest amount for 1e24 of radius at k = 0.7 on this basket: x − x_min per coin.
        uint256 exact = hook.previewDeposit(0, 1e24)[0];
        assertApproxEqRel(vpaid[0], exact, 1e9, "priced on the sphere, not on the skewed point");

        uint256 a0 = toks[0].balanceOf(attacker);
        swap(attacker, address(toks[1]), address(toks[0]), -int256(1));
        uint256 got = toks[0].balanceOf(attacker) - a0;
        assertLe(got, 1e12 + 5e7 + 1e6, "one raw unit buys par plus at most the donated dust");
    }

    function test_withdrawalLeavesAtLeastMinRadiusOrNothing() public {
        uint256 min = hook.MIN_RADIUS();
        deposit(victim, 0, 3 * min);
        vm.startPrank(victim);
        vm.expectRevert(OrbitalHook.ResidualTooSmall.selector);
        hook.withdraw(0, 3 * min - 1, zeros());
        hook.withdraw(0, 2 * min, zeros()); // leaves exactly MIN_RADIUS
        assertEq(hook.positions(0, victim), min);
        vm.expectRevert(OrbitalHook.ResidualTooSmall.selector);
        hook.withdraw(0, 1, zeros());
        hook.withdraw(0, min, zeros()); // leaves nothing
        vm.stopPrank();
        assertEq(hook.totalRadius(), 0);
    }

    function test_fullExitClearsReservesSoTheNextPoolStartsClean() public {
        uint256[] memory first = deposit(attacker, 0, 1e24);
        swap(attacker, address(toks[0]), address(toks[1]), -int256(1_000e18));
        withdraw(attacker, 0, 1e24);
        assertEq(hook.totalRadius(), 0);
        uint256[] memory x = hook.reserves();
        assertEq(x[0] + x[1], 0, "virtual reserves cleared");
        // Whatever rounding dust is left stays with the manager as the hook's claims; the next
        // opener is priced from scratch, exactly like the very first deposit was.
        uint256[] memory fresh = deposit(victim, 0, 1e24);
        assertEq(fresh[0], first[0], "equal-price opening amount");
        assertEq(fresh[1], first[1]);
        assertApproxEqAbs(hook.invariant(), 0, 1e40, "opened on the sphere");
        assertLe(hook.quoteExactInput(address(toks[1]), address(toks[0]), 1), 1e12 + 1e6);
    }
}

/// @dev Depositor whose token notifies it on transfer and who tries to trade inside the hook's
/// own settlement window.
contract ReentrantDepositor {
    OrbitalHook hook;
    PoolManager manager;
    HookableERC20 a;
    PoolKey keyAB;
    bool armed;
    uint256 public quoteInside;
    bool public swapOk;
    bytes public swapErr;

    constructor(OrbitalHook h, PoolManager m, HookableERC20 _a, HookableERC20 _b, PoolKey memory k) {
        hook = h;
        manager = m;
        a = _a;
        keyAB = k;
        _a.approve(address(hook), type(uint256).max);
        _b.approve(address(hook), type(uint256).max);
    }

    function deposit(uint256 l, uint256 r, uint256[] memory m) external returns (uint256[] memory) {
        return hook.deposit(l, r, m);
    }

    function arm() external {
        armed = true;
    }

    function onTokenReceived(address, uint256) external {
        if (!armed) return;
        armed = false;
        address b = Currency.unwrap(keyAB.currency0) == address(a)
            ? Currency.unwrap(keyAB.currency1)
            : Currency.unwrap(keyAB.currency0);
        quoteInside = hook.quoteExactOutput(address(a), b, 100_000e18);
        bool z = Currency.unwrap(keyAB.currency0) == address(a);
        try manager.swap(
            keyAB, SwapParams(z, int256(100_000e18), z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), ""
        ) returns (
            BalanceDelta
        ) {
            swapOk = true;
        } catch (bytes memory err) {
            swapOk = false;
            swapErr = err;
        }
    }
}

/// @notice Fee payout happens before any state changes and swaps are refused while the hook is
/// inside its own settlement.
contract OrbitalReentrancyTest is BasketHarness {
    address victim = makeAddr("victim");
    address trader = makeAddr("trader");
    ReentrantDepositor attacker;

    function setUp() public {
        uint8[] memory decs = new uint8[](3);
        decs[0] = 18;
        decs[1] = 18;
        decs[2] = 18;
        uint256[] memory ks = new uint256[](2);
        ks[0] = 0.74e18;
        ks[1] = 1.15e18;
        deployBasket(decs, ks, 400);
        toks[0].setNotify(true);
        fund(victim);
        fund(trader);
        attacker = new ReentrantDepositor(hook, manager, toks[0], toks[1], key(address(toks[0]), address(toks[1])));
        fund(address(attacker));
    }

    function test_swapInsideFeePayoutIsRefusedAndStateIsConsistent() public {
        deposit(victim, 1, 2_000_000e18);
        attacker.deposit(0, 1_000_000e18, maxes());
        swap(trader, address(toks[0]), address(toks[1]), -int256(100_000e18));
        uint256 honest = hook.quoteExactOutput(address(toks[0]), address(toks[1]), 100_000e18);
        assertGt(hook.pendingFees(0, address(attacker))[0], 0, "fees to pay out");

        attacker.arm();
        attacker.deposit(0, 3_000_000e18, maxes());
        assertFalse(attacker.swapOk(), "swap inside the hook's own unlock refused");
        assertEq(bytes4(attacker.swapErr()), bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)")));
        assertEq(attacker.quoteInside(), honest, "the state seen inside the payout is the committed state");
        assertConsistent(2, "after deposit");
    }

    function test_hookActionsAreNonReentrant() public {
        // deposit → fee payout → token hook → deposit again: the guard holds.
        ReentrantLp lp2 = new ReentrantLp(hook);
        fund(address(lp2));
        lp2.deposit(1, 1_000_000e18);
        swap(trader, address(toks[0]), address(toks[1]), -int256(10_000e18));
        lp2.arm();
        lp2.deposit(1, 1_000_000e18);
        assertEq(bytes4(lp2.err()), OrbitalHook.Reentrancy.selector);
    }
}

contract ReentrantLp {
    OrbitalHook hook;
    bool armed;
    bytes public err;

    constructor(OrbitalHook h) {
        hook = h;
    }

    function deposit(uint256 l, uint256 r) external {
        uint256[] memory m = new uint256[](3);
        m[0] = type(uint256).max;
        m[1] = type(uint256).max;
        m[2] = type(uint256).max;
        hook.deposit(l, r, m);
    }

    function arm() external {
        armed = true;
    }

    function onTokenReceived(address, uint256) external {
        if (!armed) return;
        armed = false;
        uint256[] memory m = new uint256[](3);
        try hook.withdraw(1, 1e18, m) {}
        catch (bytes memory e) {
            err = e;
        }
    }
}

/// @notice One frozen coin never strands the others: it is delivered as a claim and redeemed later.
contract OrbitalFrozenCoinTest is BasketHarness {
    address lp = makeAddr("lp");
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
        fund(lp);
        fund(trader);
    }

    function test_withdrawAndFeesDeliverHealthyCoinsWhenOneIsFrozen() public {
        deposit(lp, 1, 1_000_000e18);
        swap(trader, address(toks[0]), address(toks[2]), -int256(10_000e18));
        swap(trader, address(toks[2]), address(toks[1]), -int256(10_000e6)); // fees in C too
        toks[2].setPaused(true);

        uint256[] memory pending = hook.pendingFees(1, lp);
        assertGt(pending[2], 0, "C fees pending");
        uint256 a0 = toks[0].balanceOf(lp);
        vm.prank(lp);
        vm.expectEmit(true, true, false, true, address(hook));
        emit OrbitalHook.ClaimsDelivered(lp, address(toks[2]), pending[2]);
        uint256[] memory fees = hook.collectFees(1);
        assertEq(toks[0].balanceOf(lp) - a0, fees[0], "A fees moved");
        assertEq(manager.balanceOf(lp, claimId(2)), fees[2], "C fees delivered as a claim");

        a0 = toks[0].balanceOf(lp);
        uint256 b0 = toks[1].balanceOf(lp);
        vm.prank(lp);
        uint256[] memory got = hook.withdraw(1, 1_000_000e18, zeros());
        assertGt(got[0], 0);
        assertEq(toks[0].balanceOf(lp) - a0, got[0], "A delivered");
        assertEq(toks[1].balanceOf(lp) - b0, got[1], "B delivered");
        assertEq(manager.balanceOf(lp, claimId(2)), fees[2] + got[2], "C delivered as a redeemable claim");
        assertEq(hook.totalRadius(), 0);

        // Once the coin thaws the claim is redeemable through the hook, to any address.
        toks[2].setPaused(false);
        address cold = makeAddr("cold-wallet");
        vm.startPrank(lp);
        manager.setOperator(address(hook), true);
        hook.redeemClaims(address(toks[2]), fees[2] + got[2], cold);
        vm.stopPrank();
        assertEq(toks[2].balanceOf(cold), fees[2] + got[2]);
        assertEq(manager.balanceOf(lp, claimId(2)), 0);
    }

    function test_redeemClaimsFailurePaths() public {
        deposit(lp, 1, 1_000_000e18);
        toks[2].setPaused(true);
        uint256[] memory got = withdraw(lp, 1, 1_000_000e18);
        uint256 claims = got[2];
        vm.startPrank(lp);
        vm.expectRevert(); // no operator approval yet
        hook.redeemClaims(address(toks[2]), claims, lp);
        manager.setOperator(address(hook), true);
        vm.expectRevert(OrbitalHook.InvalidTokens.selector);
        hook.redeemClaims(makeAddr("not-a-basket-token"), 1, lp);
        vm.expectRevert(OrbitalHook.ZeroAmount.selector);
        hook.redeemClaims(address(toks[2]), 0, lp);
        vm.expectRevert(OrbitalHook.ZeroAddress.selector);
        hook.redeemClaims(address(toks[2]), claims, address(0));
        vm.expectRevert(); // still frozen: a redeem has no fallback
        hook.redeemClaims(address(toks[2]), claims, lp);
        vm.expectRevert(); // more than held
        hook.redeemClaims(address(toks[2]), claims + 1, lp);
        toks[2].setPaused(false);
        hook.redeemClaims(address(toks[2]), claims, lp);
        vm.stopPrank();
        assertEq(manager.balanceOf(lp, claimId(2)), 0);
    }
}

/// @notice Accounted reserves can overstate the hook's claim balance by a wei after many
/// deposits/withdrawals (per-level floors round separately from the pool floor); the last LP out
/// must still be able to leave in full.
contract OrbitalFullExitTest is BasketHarness {
    address[3] lps;
    address trader = makeAddr("trader");

    function setUp() public {
        uint8[] memory decs = new uint8[](3);
        decs[0] = 18;
        decs[1] = 18;
        decs[2] = 6;
        uint256[] memory ks = new uint256[](3);
        ks[0] = 0.74e18;
        ks[1] = 0.95e18;
        ks[2] = 1.15e18;
        deployBasket(decs, ks, 400);
        lps[0] = makeAddr("lp0");
        lps[1] = makeAddr("lp1");
        lps[2] = makeAddr("lp2");
        fund(lps[0]);
        fund(lps[1]);
        fund(lps[2]);
        fund(trader);
    }

    function test_everyoneCanLeaveAfterMixedActivity() public {
        deposit(lps[1], 1, 2e24);
        deposit(lps[0], 2, 3e24);
        deposit(lps[2], 1, 3e24);
        swap(trader, address(toks[0]), address(toks[1]), int256(540_027e18));
        deposit(lps[0], 2, 3e24);
        deposit(lps[1], 0, 1e24);
        deposit(lps[2], 0, 1e24);
        withdraw(lps[2], 0, 333_333.33e18);
        withdraw(lps[1], 1, 666_666.66e18);
        swap(trader, address(toks[2]), address(toks[0]), int256(135_770e18));
        deposit(lps[2], 2, 2e24);
        swap(trader, address(toks[2]), address(toks[1]), int256(694_169e18));
        swap(trader, address(toks[2]), address(toks[1]), -int256(274_323e6));
        deposit(lps[0], 1, 2e24);
        drainAll();
    }

    function testFuzz_everyoneCanLeaveAfterRandomActivity(uint256 seed) public {
        for (uint256 step = 0; step < 24; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 4;
            address lp = lps[(r >> 8) % 3];
            uint256 l = (r >> 16) % 3;
            if (op == 0 || hook.totalRadius() == 0) {
                deposit(lp, l, 1e24 + (r >> 32) % 3e24);
            } else if (op == 1) {
                uint256 held = hook.positions(l, lp);
                if (held > 0) {
                    uint256 part = held / 3 + (r >> 32) % (held / 2 + 1);
                    if (part > held) part = held;
                    if (part == 0) continue;
                    vm.prank(lp);
                    (bool ok,) = address(hook).call(abi.encodeCall(hook.withdraw, (l, part, zeros())));
                    ok; // a residual below MIN_RADIUS is refused, which is fine here
                }
            } else {
                uint256 i = (r >> 40) % 3;
                uint256 j = (i + 1 + (r >> 48) % 2) % 3;
                uint256 units = 1 + (r >> 56) % 200_000;
                int256 signed =
                    op == 2 ? -int256(units * 10 ** toks[i].decimals()) : int256(units * 10 ** toks[j].decimals());
                trySwap(trader, address(toks[i]), address(toks[j]), signed);
            }
        }
        drainAll();
    }

    function drainAll() internal {
        for (uint256 l = 0; l < 3; l++) {
            for (uint256 p = 0; p < 3; p++) {
                uint256 held = hook.positions(l, lps[p]);
                if (held == 0) continue;
                vm.prank(lps[p]);
                hook.withdraw(l, held, zeros());
                vm.prank(lps[p]);
                hook.collectFees(l);
            }
        }
        assertEq(hook.totalRadius(), 0, "everyone left");
        for (uint256 k = 0; k < 3; k++) {
            assertEq(hook.reserves()[k], 0, "virtual reserves cleared");
        }
    }
}
