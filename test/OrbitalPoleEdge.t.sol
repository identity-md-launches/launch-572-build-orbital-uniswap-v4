// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BasketHarness} from "./utils/BasketHarness.sol";
import {OrbitalHook} from "../src/OrbitalHook.sol";
import {HookableERC20} from "./mocks/HookableERC20.sol";
import {CorruptibleOrbitalHook} from "./mocks/CorruptibleOrbitalHook.sol";

/// @notice Adversarial follow-up to the revision's all-coin pole check. The check runs on the
/// state a trade *commits*; a trade that crosses a tick plane is priced in two segments, and the
/// second segment starts from the plane landing, which no check looks at. If that landing had a
/// coin past its pole the solvers' dust shortcuts would price the rest of the trade at nothing,
/// while the committed state could still pass. So beyond "no committed state is past a pole"
/// (the author's fuzz) this asserts the price itself: along a trade that adds i and removes j the
/// marginal price (r − u_j)/(r − u_i) can only rise, so no trade may be paid at a small fraction of
/// the marginal price at its start. Reviewer's basket, started from the near-pole state.
contract OrbitalPoleEdgeTest is BasketHarness {
    address lp = makeAddr("lp");
    address lp2 = makeAddr("lp2");
    address trader = makeAddr("trader");

    function setUp() public {
        uint8[] memory decs = new uint8[](4);
        decs[0] = 18;
        decs[1] = 6;
        decs[2] = 18;
        decs[3] = 8;
        uint256[] memory ks = new uint256[](4);
        ks[0] = 1.01e18;
        ks[1] = 1.1e18;
        ks[2] = 1.3e18;
        ks[3] = 1.5e18;
        deployBasket(decs, ks, 400);
        fund(lp);
        fund(lp2);
        fund(trader);
    }

    /// Same sequence as the author's `OrbitalPole.t.sol`: coin 2 at u₂/r_int ≈ 0.97, ticks 0 and 1
    /// pinned.
    function nearPole() internal {
        deposit(lp, 3, 2e24);
        deposit(lp, 0, 1e24);
        swap(trader, address(toks[2]), address(toks[1]), -784_023e18);
        swap(trader, address(toks[2]), address(toks[0]), -84_206e18);
        deposit(lp, 1, 2.05e24);
        deposit(lp, 1, 2.05e24);
        swap(trader, address(toks[2]), address(toks[1]), -303_068e18);
        deposit(lp, 2, 1.07e24);
        assertEq(hook.boundaryMask(), 3, "ticks 0 and 1 pinned");
    }

    /// @dev (r − u_j)/(r − u_i), WAD; zero when undefined.
    function marginalPriceWad(uint256 i, uint256 j) internal view returns (uint256) {
        (int256[] memory u, uint256 r) = interior();
        if (r == 0 || u[i] >= int256(r) || u[j] >= int256(r)) return 0;
        return uint256(int256(r) - u[j]) * 1e18 / uint256(int256(r) - u[i]);
    }

    function scaleOf(uint256 k) internal view returns (uint256) {
        return 10 ** (18 - toks[k].decimals());
    }

    /// Random trades (both kinds, every pair, up to 300k units), deposits and withdrawals from the
    /// near-pole state: every executed trade is paid at least a quarter of its starting marginal
    /// price, no committed state has a coin past a pole, and the point never sinks inside the torus
    /// beyond the fail-safe. Any giveaway from a plane landing past a pole shows up here as a trade
    /// paid at a tiny fraction of the marginal price.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_noTradeIsPricedFarBelowItsStartingMarginalPrice(uint256 seed) public {
        nearPole();
        uint256 traded;
        for (uint256 step = 0; step < 16; step++) {
            uint256 rnd = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = rnd % 10;
            if (op == 0) {
                deposit(lp2, (rnd >> 8) % 4, 5e23 + (rnd >> 16) % 1e24);
                assertBelowPoles("deposit");
            } else if (op == 1) {
                uint256 l = (rnd >> 8) % 4;
                uint256 held = hook.positions(l, lp2);
                if (held >= 2e18) {
                    withdraw(lp2, l, held / 2);
                    assertBelowPoles("withdraw");
                }
            } else {
                uint256 i = (rnd >> 40) % 4;
                uint256 j = (i + 1 + (rnd >> 48) % 3) % 4;
                uint256 units = 1 + (rnd >> 56) % 300_000;
                bool exactIn = op < 6;
                int256 amt = exactIn
                    ? -int256(units * 10 ** toks[i].decimals())
                    : int256(units / 3 * 10 ** toks[j].decimals() + 1);
                uint256 p0 = marginalPriceWad(i, j);
                uint256 inBefore = toks[i].balanceOf(trader);
                uint256 outBefore = toks[j].balanceOf(trader);
                (bool ok,) = trySwap(trader, address(toks[i]), address(toks[j]), amt);
                if (!ok) continue;
                traded++;
                uint256 paid = inBefore - toks[i].balanceOf(trader);
                uint256 got = toks[j].balanceOf(trader) - outBefore;
                if (p0 > 0 && got > 0) {
                    // paid ≥ got · p0 / 4, with one raw unit of either side as rounding slack.
                    uint256 floorWad = got * scaleOf(j) * p0 / 1e18 / 4;
                    assertGe(paid * scaleOf(i) + 2 * scaleOf(i) + 2 * scaleOf(j), floorWad, "giveaway");
                }
                assertConsistent(10, "swap");
                assertBelowPoles("swap");
            }
        }
        assertGt(traded, 0, "some trades went through");
    }

    /// The refusal is clean: a trade refused for carrying a third coin past its pole changes no
    /// state, charges nothing, and the same trade split in two halves (each allowed on its own)
    /// is refused at whichever half would cross — the check is on the state, not on the size.
    function test_poleRefusalIsStatelessAndSplittingDoesNotEvadeIt() public {
        nearPole();
        swap(trader, address(toks[0]), address(toks[1]), int256(187_282e6));
        uint256[] memory xBefore = hook.reserves();
        uint256 maskBefore = hook.boundaryMask();
        uint256 c3 = toks[3].balanceOf(trader);
        (bool ok,) = trySwap(trader, address(toks[3]), address(toks[0]), -715_811e8);
        assertFalse(ok);
        assertEq(toks[3].balanceOf(trader), c3, "nothing charged");
        uint256[] memory xAfter = hook.reserves();
        for (uint256 k = 0; k < 4; k++) {
            assertEq(xAfter[k], xBefore[k], "refused trade touched the reserves");
        }
        assertEq(hook.boundaryMask(), maskBefore);
        // Halves: the first may pass, the sum may not. Whatever is committed keeps every coin
        // below its pole.
        uint256 halves;
        for (uint256 h = 0; h < 2; h++) {
            (ok,) = trySwap(trader, address(toks[3]), address(toks[0]), -357_906e8);
            if (ok) halves++;
            assertBelowPoles("half");
        }
        assertLt(halves, 2, "splitting the refused trade in two must not get the whole of it through");
    }
}

/// @notice The fail-safe's recovery path. A point forced inside the torus beyond the tolerance
/// (test-only subclass; no production path does this) freezes swaps and quotes. Deposits, fee
/// collection and withdrawals must keep working, a withdrawal must not deepen or lift the freeze
/// (it scales surplus and radius alike), and a large enough interior deposit must lift it, because
/// the absolute surplus stays while the tolerance grows with the square of the radius.
contract OrbitalFailSafeRecoveryTest is BasketHarness {
    CorruptibleOrbitalHook corruptible;
    address lp = makeAddr("lp");
    address rescuer = makeAddr("rescuer");
    address trader = makeAddr("trader");

    function setUp() public {
        manager = new PoolManager(address(this));
        router = new PoolSwapTest(manager);
        uint8[] memory decs = new uint8[](3);
        decs[0] = 18;
        decs[1] = 18;
        decs[2] = 6;
        address[] memory basket = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            HookableERC20 t = new HookableERC20(decs[i]);
            toks.push(t);
            basket[i] = address(t);
        }
        uint256[] memory ks = new uint256[](2);
        ks[0] = 0.74e18;
        ks[1] = 1.15e18;
        bytes memory code = abi.encodePacked(
            type(CorruptibleOrbitalHook).creationCode,
            abi.encode(IPoolManager(address(manager)), owner, address(0), basket, decs, ks, uint24(400))
        );
        bytes32 salt = mine(code);
        corruptible = new CorruptibleOrbitalHook{salt: salt}(
            IPoolManager(address(manager)), owner, address(0), basket, decs, ks, 400
        );
        hook = OrbitalHook(address(corruptible));
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                manager.initialize(key(basket[i], basket[j]), SQRT_PRICE_1_1);
            }
        }
        fund(lp);
        fund(rescuer);
        fund(trader);
        deposit(lp, 1, 1e24);
        swap(trader, address(toks[0]), address(toks[1]), -1_000e18); // some fees to collect
    }

    function tolerance() internal view returns (uint256) {
        (uint256 r,,) = hook.consolidated();
        return r * (r / 1e6) + 4 * r * 1e12;
    }

    function frozen() internal view returns (bool) {
        try hook.quoteExactInput(address(toks[0]), address(toks[1]), 1e18) {
            return false;
        } catch (bytes memory err) {
            assertEq(bytes4(err), OrbitalHook.InvariantViolated.selector, "refused for another reason");
            return true;
        }
    }

    function test_frozenPoolStillAcceptsDepositsAndFeesAndALargeDepositRestoresTrading() public {
        (, uint256 r) = interior();
        corruptible.nudgeReserve(0, int256(r / 100_000)); // 0.001% of r inside: ≈ 11× the tolerance
        assertLt(hook.invariant(), -int256(tolerance()), "inside beyond the tolerance");
        assertTrue(frozen(), "swaps and quotes are frozen");
        (bool ok,) = trySwap(trader, address(toks[1]), address(toks[0]), int256(1e18));
        assertFalse(ok);

        // Fees and previews keep working; a small deposit lands and does not lift the freeze.
        uint256[] memory fees = hook.pendingFees(1, lp);
        assertGt(fees[0], 0);
        vm.prank(lp);
        uint256[] memory got = hook.collectFees(1);
        assertEq(got[0], fees[0], "fees collectable while frozen");
        uint256[] memory preview = hook.previewDeposit(1, 1e22);
        uint256[] memory put = deposit(rescuer, 1, 1e22);
        assertEq(put[0], preview[0], "deposit matches preview while frozen");
        assertTrue(frozen(), "a 1% deposit does not lift the freeze");

        // A withdrawal scales surplus and tolerance alike: still frozen, still allowed.
        withdraw(lp, 1, 5e23);
        assertTrue(frozen(), "withdrawals do not lift the freeze");
        assertGt(toks[0].balanceOf(lp), 0);

        // The rescue: an interior deposit large enough that (r + ρ)²/1e6 covers 2·(r + ρ)·δ.
        (, r) = interior();
        int256 f = hook.invariant();
        uint256 surplus = uint256(-f) / (2 * r); // δ: how far inside, in WAD of radius
        uint256 needed = 2_000_000 * surplus; // r + ρ must reach 2e6·δ
        assertGt(needed, r, "the rescue needs more radius than the pool has");
        uint256 rho = needed - r + needed / 10;
        uint256[] memory rescue = deposit(rescuer, 1, rho);
        assertFalse(frozen(), "a large enough deposit lifts the freeze");
        assertGe(hook.invariant(), -int256(tolerance()));
        uint256 q = hook.quoteExactInput(address(toks[0]), address(toks[1]), 1e18);
        assertGt(q, 0);
        swap(trader, address(toks[1]), address(toks[0]), -1e18);
        assertConsistent(10, "after the rescue");

        // The rescuer's exit is their deposit to within the forced offset (1e-5 of the radius): the
        // test-only nudge is phantom accounting the pool pays out pro rata, so the comparison can
        // only be made at that resolution. Nobody is enriched or impoverished by the rescue.
        uint256[] memory back = withdraw(rescuer, 1, rho);
        for (uint256 k = 0; k < 3; k++) {
            assertGe(back[k] + back[k] / 10_000 + 1, rescue[k], "rescuer lost more than 0.01%");
            assertLe(back[k], rescue[k] + rescue[k] / 10_000 + 1, "rescuer gained more than 0.01%");
        }
    }
}
