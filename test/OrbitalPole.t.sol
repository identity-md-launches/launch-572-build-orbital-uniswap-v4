// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BasketHarness} from "./utils/BasketHarness.sol";
import {OrbitalHook} from "../src/OrbitalHook.sol";
import {HookableERC20} from "./mocks/HookableERC20.sol";
import {CorruptibleOrbitalHook} from "./mocks/CorruptibleOrbitalHook.sol";

/// @notice The pole constraint holds for every coin, not only the one being sold. With ticks
/// pinned, a coin's boundary share follows the pool's direction, so a trade between two other
/// coins moves a third coin's interior reserve; a coin already near its pole must not be carried
/// across by such a trade, because past the pole the solvers would hand it (and then healthy
/// coins) out for one raw unit. Reviewer's basket: decimals 18/6/18/8, ticks 1.01/1.1/1.3/1.5.
contract OrbitalPoleTest is BasketHarness {
    address lp = makeAddr("lp");
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
        fund(trader);
    }

    /// Drives coin 2 to u₂/r_int ≈ 0.97 with ordinary sales and deposits (ticks 0 and 1 pinned),
    /// exactly as in the reported reproduction.
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
        (int256[] memory u, uint256 r) = interior();
        assertGt(u[2] * 1e4 / int256(r), 9600, "coin 2 near its pole");
        assertLt(u[2], int256(r), "but still on the right side");
        assertBelowPoles("setup");
    }

    function test_tradeBetweenOtherCoinsCannotCarryAThirdCoinPastItsPole() public {
        nearPole();

        // A trade between coins 0 and 1 that keeps every coin below its pole goes through.
        swap(trader, address(toks[0]), address(toks[1]), int256(187_282e6));
        assertBelowPoles("trade between healthy coins");

        // The reported sale of coin 3 for coin 0 would carry coin 2 to u₂/r_int ≈ 1.0012 without
        // touching x₂. It is refused.
        uint256 x2Before = hook.reserves()[2];
        (bool ok, bytes memory ret) = trySwap(trader, address(toks[3]), address(toks[0]), -715_811e8);
        assertFalse(ok, "trade carrying a third coin past its pole must be refused");
        assertTrue(contains(ret, OrbitalHook.SwapTooLarge.selector), "refused as SwapTooLarge");
        assertEq(hook.reserves()[2], x2Before, "nothing committed");
        assertBelowPoles("after the refusal");

        // The quote view refuses it the same way.
        vm.expectRevert(OrbitalHook.SwapTooLarge.selector);
        hook.quoteExactInput(address(toks[3]), address(toks[0]), 715_811e8);

        // A smaller sale of coin 3 that leaves coin 2 on the right side is fine.
        swap(trader, address(toks[3]), address(toks[0]), -100_000e8);
        assertBelowPoles("smaller trade");

        // The near-pole coin can still be bought (that pulls it back from the pole) and is priced,
        // not given away: the reported 59,760 of coin 2 for coin 3 cost one raw unit before the fix.
        (int256[] memory u, uint256 r) = interior();
        int256 u2Before = u[2];
        uint256 c3 = toks[3].balanceOf(trader);
        swap(trader, address(toks[3]), address(toks[2]), int256(59_760e18));
        uint256 paid = c3 - toks[3].balanceOf(trader);
        assertGt(paid, 1_000e8, "a depegged coin is cheap, never free");
        assertLt(paid, 59_760e8, "and cheaper than par");
        (u, r) = interior();
        assertLt(u[2], u2Before, "buying the coin moves it away from its pole");
        assertBelowPoles("after buying the near-pole coin");

        // Healthy coins keep their price: 1,000 of coin 0 costs on the order of 1,000 coin 3
        // (coin 3 is the pool's scarcest coin here, so coin 0 is somewhat cheaper than par).
        c3 = toks[3].balanceOf(trader);
        swap(trader, address(toks[3]), address(toks[0]), int256(1_000e18));
        paid = c3 - toks[3].balanceOf(trader);
        assertGt(paid, 500e8, "1,000 healthy stablecoins are not sold for dust");
        assertLt(paid, 1_100e8, "nor above par");
        assertBelowPoles("end");
    }

    /// A coin sitting at its pole is pulled back by trades that move the other coins towards the
    /// peg, so the pool is never stuck: arbitrage of the cheap coin and of the others both work.
    function test_poleCoinIsPulledBackByTradesTowardsThePeg() public {
        nearPole();
        (int256[] memory u, uint256 r) = interior();
        int256 before = u[2] * 1e6 / int256(r);
        // Coin 1 was bought heavily (u₁ low); selling it back reduces ‖w‖, which lowers coin 2's
        // interior reserve without any coin-2 trade.
        swap(trader, address(toks[1]), address(toks[0]), -200_000e6);
        (u, r) = interior();
        assertLt(u[2] * 1e6 / int256(r), before, "trade towards the peg pulls the third coin back");
        assertBelowPoles("towards the peg");
    }

    function contains(bytes memory data, bytes4 sel) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i = 0; i + 4 <= data.length; i++) {
            if (data[i] == sel[0] && data[i + 1] == sel[1] && data[i + 2] == sel[2] && data[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }
}

/// @notice Random large trades, deposits and withdrawals on the project's 3-coin basket never leave
/// a coin past its pole nor the point inside the torus beyond the start-of-trade tolerance (the
/// reported fuzz found u/r = 1.0054 on this basket within 12 runs before the fix).
contract OrbitalPoleFuzzTest is BasketHarness {
    address lp = makeAddr("lp");
    address lp2 = makeAddr("lp2");
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
        fund(lp);
        fund(lp2);
        fund(trader);
    }

    function testFuzz_noCoinIsCarriedPastItsPole(uint256 seed) public {
        deposit(lp, 0, 2e24);
        deposit(lp, 1, 2e24);
        deposit(lp, 2, 2e24);
        uint256 traded;
        for (uint256 step = 0; step < 24; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 8;
            if (op == 0) {
                deposit(lp2, (r >> 8) % 3, 1e24 + (r >> 16) % 2e24);
                assertConsistent(2, "deposit");
                assertBelowPoles("deposit");
            } else if (op == 1) {
                uint256 l = (r >> 8) % 3;
                uint256 held = hook.positions(l, lp2);
                if (held >= 2e18) {
                    withdraw(lp2, l, held / 2);
                    assertConsistent(2, "withdraw");
                    assertBelowPoles("withdraw");
                }
            } else {
                uint256 i = (r >> 40) % 3;
                uint256 j = (i + 1 + (r >> 48) % 2) % 3;
                uint256 units = 1 + (r >> 56) % 1_500_000;
                bool exactIn = op < 5;
                int256 amt = exactIn
                    ? -int256(units * 10 ** toks[i].decimals())
                    : int256(units / 2 * 10 ** toks[j].decimals() + 1);
                (bool ok,) = trySwap(trader, address(toks[i]), address(toks[j]), amt);
                if (ok) {
                    traded++;
                    assertConsistent(10, "swap");
                    assertBelowPoles("swap");
                }
            }
        }
        assertGt(traded, 0, "some trades went through");
    }
}

/// @notice Fail-safe: a point inside the torus by more than rounding (unreachable through the
/// hook's own paths; forced here with a test-only subclass) freezes swaps and quotes, never
/// withdrawals. Inside by rounding only, the pool keeps trading.
contract OrbitalOffSurfaceTest is BasketHarness {
    CorruptibleOrbitalHook corruptible;
    address lp = makeAddr("lp");
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
        fund(trader);
        deposit(lp, 1, 1e24);
        deposit(lp, 0, 1e24);
    }

    function test_pointDeepInsideTheTorusFreezesSwapsNotWithdrawals() public {
        swap(trader, address(toks[0]), address(toks[1]), -1_000e18);
        assertBelowPoles("before corruption");

        // Push the point inside the sphere by 0.1% of the radius on coin 0: F ≈ −2(r − u₀)·δ,
        // about r²·4e-4, far beyond the tolerance (r²·1e-6 + four raw units).
        (, uint256 r) = interior();
        corruptible.nudgeReserve(0, int256(r / 1_000));
        assertLt(hook.invariant(), -int256(r * (r / 1e6) + 4 * r * 1e12), "deep inside");

        vm.expectRevert(OrbitalHook.InvariantViolated.selector);
        hook.quoteExactOutput(address(toks[1]), address(toks[0]), 1_000e18);
        vm.expectRevert(OrbitalHook.InvariantViolated.selector);
        hook.quoteExactInput(address(toks[0]), address(toks[1]), 1_000e18);
        (bool ok,) = trySwap(trader, address(toks[1]), address(toks[0]), int256(1_000e18));
        assertFalse(ok, "exact-output swap refused: the surplus is not for sale at one raw unit");
        (ok,) = trySwap(trader, address(toks[2]), address(toks[1]), -1_000e6);
        assertFalse(ok, "exact-input swap refused too");

        // LPs can still leave (the withdrawal also pays out the fees of the earlier swap).
        uint256 b0 = toks[0].balanceOf(lp);
        uint256 fees0 = hook.pendingFees(0, lp)[0];
        uint256[] memory out = withdraw(lp, 0, 1e24);
        assertGt(out[0], 0);
        assertEq(toks[0].balanceOf(lp) - b0, out[0] + fees0);
    }

    function test_pointInsideByRoundingStillTrades() public {
        // One raw unit of the 6-decimal coin (1e12 WAD) is what an exact-input swap can leave
        // inside the pool; well within the tolerance, so trading continues.
        corruptible.nudgeReserve(2, int256(1e12));
        assertBelowPoles("dust inside");
        uint256 quoted = hook.quoteExactInput(address(toks[0]), address(toks[1]), 1_000e18);
        assertGt(quoted, 0);
        swap(trader, address(toks[0]), address(toks[1]), -1_000e18);
        assertConsistent(10, "swap after dust");
    }
}
