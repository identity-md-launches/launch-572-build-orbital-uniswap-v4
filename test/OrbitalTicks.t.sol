// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {BasketHarness} from "./utils/BasketHarness.sol";
import {OrbitalHook} from "../src/OrbitalHook.sol";

/// @notice Tick pinning and unpinning along trades that are not monotonic in α: a return trade
/// through the peg, states left exactly on a plane, and one-unit rounding after deposits.
contract OrbitalReturnTradeTest is BasketHarness {
    uint256 constant TIGHT = 0;
    uint256 constant MID = 1;
    uint256 constant WIDE = 2;
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address lp3 = makeAddr("lp3");
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
        fund(lp1);
        fund(lp2);
        fund(lp3);
        fund(trader);
    }

    /// A pinned tick must rejoin the interior where the return path meets its plane, even though
    /// the trade ends with α above where it started (it dips through the peg and comes out on the
    /// other side). Otherwise the tick stays frozen on the wrong side and the next deposit drops
    /// the pool inside the torus.
    function test_returnTradeThroughPegUnpinsAndRepins() public {
        deposit(lp1, WIDE, 1e24);
        deposit(lp2, TIGHT, 3e24);
        uint256 b0 = toks[1].balanceOf(trader);
        swap(trader, address(toks[2]), address(toks[1]), -int256(500_000e6)); // C-heavy: tight pins
        uint256 gotB = toks[1].balanceOf(trader) - b0;
        assertEq(hook.boundaryMask(), 1 << TIGHT, "tight tick pinned");
        assertConsistent(10, "after pin");

        // Sell everything back: the tick rejoins the interior where the path meets its plane; from
        // there all 4e24 of radius serves the trade, which therefore ends well inside the peg
        // region on the B-heavy side with the tick interior.
        vm.recordLogs();
        swap(trader, address(toks[1]), address(toks[2]), -int256(gotB));
        assertConsistent(10, "after return");
        assertEq(hook.boundaryMask(), 0, "tick rejoined the interior");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("LevelCrossed(uint256,bool)");
        uint256 crossings;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                assertEq(uint256(logs[i].topics[1]), TIGHT);
                assertFalse(abi.decode(logs[i].data, (bool)), "the crossing is an unpin");
                crossings++;
            }
        }
        assertEq(crossings, 1, "exactly one crossing");
        assertLt(hook.alphaIntNorm(), 0.74e18, "interior below the tight plane");
        uint256[] memory x = hook.reserves();
        uint256 diff = x[1] > x[2] ? x[1] - x[2] : x[2] - x[1];
        assertLt(diff * 1000, x[1], "back within 0.1% of the peg between B and C");

        deposit(lp3, MID, 3e24);
        assertConsistent(10, "after deposit");
        // 1 wei of A buys at most the sub-raw-unit dust of the 6-decimal coin (< 1e12 wei) that the
        // return trade left inside the surface; on the unfixed code it bought ~267,000 B.
        uint256 q = hook.quoteExactInput(address(toks[0]), address(toks[1]), 1);
        assertLe(q, 1e12, "1 wei buys at most one raw unit of dust");
        // And a round trip through the fresh deposit never profits.
        uint256 a0 = toks[0].balanceOf(trader);
        uint256 b1 = toks[1].balanceOf(trader);
        swap(trader, address(toks[0]), address(toks[1]), -int256(10_000e18));
        swap(trader, address(toks[1]), address(toks[0]), -int256(toks[1].balanceOf(trader) - b1));
        assertLt(toks[0].balanceOf(trader), a0, "round trip costs fees and spread");
    }

    /// A trade that would end with ‖w‖ below s_bound cannot be committed; the stepper never
    /// produces one, so every random sequence of trades, deposits and withdrawals keeps the pool on
    /// the torus with every tick on the right side of its plane.
    function testFuzz_randomActivityKeepsTicksConsistent(uint256 seed) public {
        deposit(lp1, WIDE, 1e24);
        deposit(lp2, TIGHT, 2e24);
        deposit(lp3, MID, 1e24);
        for (uint256 step = 0; step < 16; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 6;
            if (op == 0) {
                address lp = r >> 8 & 1 == 0 ? lp1 : lp3;
                deposit(lp, (r >> 16) % 3, 1e24 + (r >> 32) % 2e24);
                assertConsistent(2, "deposit");
            } else if (op == 1) {
                uint256 l = (r >> 16) % 3;
                uint256 held = hook.positions(l, lp2);
                if (held >= 2e18) {
                    uint256 part = held / 2;
                    withdraw(lp2, l, part);
                    assertConsistent(2, "withdraw");
                }
            } else {
                uint256 i = (r >> 40) % 3;
                uint256 j = (i + 1 + (r >> 48) % 2) % 3;
                uint256 units = 1 + (r >> 56) % 400_000;
                bool exactIn = op < 4;
                int256 amt = exactIn
                    ? -int256(units * 10 ** toks[i].decimals())
                    : int256(units / 2 * 10 ** toks[j].decimals() + 1);
                (bool ok,) = trySwap(trader, address(toks[i]), address(toks[j]), amt);
                if (ok) assertConsistent(10, "swap");
            }
        }
    }

    /// The smallest trade that pins a tick leaves the interior exactly on its plane; a deposit
    /// then moves it one unit below. The next return trade must still unpin the tick.
    function test_tickOnItsPlaneRejoinsAfterDepositNudge() public {
        deposit(lp1, TIGHT, 1e24);
        deposit(lp1, WIDE, 2e24);
        uint256 lo = 1e18;
        uint256 hi = 600_000e18;
        assertTrue(pins(hi));
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (pins(mid)) hi = mid;
            else lo = mid;
        }
        swap(trader, address(toks[0]), address(toks[1]), -int256(hi));
        assertEq(hook.boundaryMask(), 1 << TIGHT);
        assertApproxEqAbs(hook.alphaIntNorm(), 0.74e18, 2, "landed on the plane");

        deposit(lp1, WIDE, 1e24);
        assertEq(hook.boundaryMask(), 1 << TIGHT, "deposit keeps the mask");
        assertApproxEqAbs(hook.alphaIntNorm(), 0.74e18, 3, "nudged by rounding only");

        uint256 a0 = toks[0].balanceOf(trader);
        vm.expectEmit(true, false, false, true, address(hook));
        emit OrbitalHook.LevelCrossed(TIGHT, false);
        swap(trader, address(toks[1]), address(toks[0]), -int256(250_000e18));
        assertEq(hook.boundaryMask(), 0, "tight tick rejoined the interior");
        assertConsistent(10, "after return");
        // Served by all the liquidity: close to par for a 250k trade against 4M of radius.
        uint256 got = toks[0].balanceOf(trader) - a0;
        assertGt(got, 249_000e18);
    }

    function pins(uint256 amount) internal returns (bool pinned) {
        uint256 snap = vm.snapshotState();
        swap(trader, address(toks[0]), address(toks[1]), -int256(amount));
        pinned = hook.boundaryMask() == 1 << TIGHT;
        vm.revertToState(snap);
    }
}

/// @notice With only pinned liquidity left (every interior LP withdrew during a depeg), a new
/// interior position opens on the highest pinned plane and trading resumes.
contract OrbitalDeadlockRecoveryTest is BasketHarness {
    address pinnedLp = makeAddr("pinnedLp");
    address interiorLp = makeAddr("interiorLp");
    address newLp = makeAddr("newLp");
    address trader = makeAddr("trader");

    function setUp() public {
        uint8[] memory decs = new uint8[](2);
        decs[0] = 18;
        decs[1] = 18;
        uint256[] memory ks = new uint256[](2);
        ks[0] = 0.5e18;
        ks[1] = 0.7e18;
        deployBasket(decs, ks, 400);
        fund(pinnedLp);
        fund(interiorLp);
        fund(newLp);
        fund(trader);
    }

    function test_interiorReopensOnThePinnedPlane() public {
        deposit(pinnedLp, 0, 1e24);
        deposit(interiorLp, 1, 2e24);
        for (uint256 i = 0; i < 8 && hook.boundaryMask() != 1; i++) {
            swap(trader, address(toks[0]), address(toks[1]), -int256(300_000e18));
        }
        assertEq(hook.boundaryMask(), 1, "tick 0 pinned");
        withdraw(interiorLp, 1, 2e24);
        (uint256 r,,) = hook.consolidated();
        assertEq(r, 0, "no interior left");
        assertEq(hook.alphaIntNorm(), 0.5e18, "position reported as the pinned plane");

        // Nothing trades without an interior, but the pool is not stuck: anyone can open one.
        (bool ok,) = trySwap(trader, address(toks[1]), address(toks[0]), -int256(1e18));
        assertFalse(ok, "no interior liquidity to trade against");

        uint256[] memory want = hook.previewDeposit(1, 1e24);
        vm.prank(newLp);
        uint256[] memory paid = hook.deposit(1, 1e24, want);
        assertEq(paid[0], want[0]);
        (r,,) = hook.consolidated();
        assertEq(r, 1e24, "interior reopened");
        assertApproxEqAbs(hook.alphaIntNorm(), 0.5e18, 10, "opened exactly on the pinned plane");
        assertConsistent(10, "after reopening");
        // Trading away from the peg works again and keeps the tick pinned.
        uint256 b0 = toks[1].balanceOf(trader);
        swap(trader, address(toks[0]), address(toks[1]), -int256(1e18));
        assertGt(toks[1].balanceOf(trader), b0, "trading works again");
        assertEq(hook.boundaryMask(), 1);
        assertConsistent(10, "after trading away");

        // A deposit into the pinned tick itself while r_int = 0 is a boundary deposit on its circle.
        withdraw(newLp, 1, 1e24);
        (r,,) = hook.consolidated();
        assertEq(r, 0);
        uint256[] memory boundaryPaid = deposit(newLp, 0, 1e24);
        assertEq(hook.boundaryMask(), 1, "still only pinned liquidity");
        assertConsistent(10, "boundary deposit without interior");
        assertEq(hook.totalRadius(), 2e24);
        assertGt(boundaryPaid[0] + boundaryPaid[1], 0);

        // Reopen once more and trade back towards the peg: the pinned tick rejoins at its plane.
        deposit(newLp, 1, 1e24);
        swap(trader, address(toks[1]), address(toks[0]), -int256(100_000e18));
        assertEq(hook.boundaryMask(), 0, "pinned tick rejoined the interior");
        assertConsistent(10, "after trading back");

        withdraw(pinnedLp, 0, 1e24);
        withdraw(newLp, 0, 1e24);
        withdraw(newLp, 1, 1e24);
        assertEq(hook.totalRadius(), 0);
    }
}
