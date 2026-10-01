// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OrbitalFixture} from "./utils/OrbitalFixture.sol";
import {OrbitalHook} from "../src/OrbitalHook.sol";
import {OrbitalMath} from "../src/libraries/OrbitalMath.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {BaseHook} from "../src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract OrbitalHookTest is OrbitalFixture {
    using PoolIdLibrary for PoolKey;

    uint256 constant R = 1_000_000e18; // radius per level in the default seeding

    /// @dev 1M radius concentrated + 2M radius full-range.
    function seed() internal {
        depositAs(lp, TIGHT, R);
        depositAs(lp, WIDE, 2 * R);
    }

    /// @dev Deploys at a correctly mined address so constructor validation (not the address
    /// check) is what reverts.
    function deployRaw(address[] memory b, uint256[] memory ks, uint24 fee) internal {
        // No external calls here: `vm.expectRevert` must apply to the CREATE2 itself.
        uint8[] memory decs = new uint8[](b.length);
        for (uint256 i = 0; i < b.length; i++) {
            decs[i] = 18;
        }
        deployRawDecimals(b, decs, ks, fee);
    }

    function deployRawDecimals(address[] memory b, uint8[] memory decs, uint256[] memory ks, uint24 fee) internal {
        bytes memory code = abi.encodePacked(
            type(OrbitalHook).creationCode,
            abi.encode(IPoolManager(address(manager)), owner, guardian, b, decs, ks, fee)
        );
        bytes32 salt = mineSalt(address(this), code, FLAGS);
        new OrbitalHook{salt: salt}(IPoolManager(address(manager)), owner, guardian, b, decs, ks, fee);
    }

    // ---- permissions & access control -------------------------------------------------------

    function test_permissionsMatchAddressBits() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeAddLiquidity && p.beforeSwap && p.beforeSwapReturnDelta);
        assertFalse(p.afterSwap || p.afterInitialize || p.beforeRemoveLiquidity || p.afterSwapReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), FLAGS);
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_callbacksRefuseNonPoolManager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), keyAB, SQRT_PRICE_1_1);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), keyAB, SwapParams(true, -1e18, SQRT_PRICE_1_1 / 2), "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(this), keyAB, ModifyLiquidityParams(-60, 60, 1e18, bytes32(0)), "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.unlockCallback("");
        // Unimplemented callbacks refuse too, even from the manager.
        vm.prank(address(manager));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        IHooks(address(hook)).afterInitialize(address(this), keyAB, SQRT_PRICE_1_1, 0);
        vm.prank(address(manager));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        IHooks(address(hook))
            .afterSwap(address(this), keyAB, SwapParams(true, -1e18, SQRT_PRICE_1_1 / 2), toBalanceDelta(0, 0), "");
    }

    function test_initializeRegistersOrbitalPairs() public view {
        (bool orbital, uint8 i0, uint8 i1) = hook.pools(keyAB.toId());
        assertTrue(orbital);
        (uint8 a, uint8 b) = address(usdA) < address(usdB) ? (0, 1) : (1, 0);
        assertEq(i0, a);
        assertEq(i1, b);
    }

    function test_initializeNonBasketPoolIsPassThrough() public {
        MockERC20 orb = new MockERC20("Orbital", "ORB", 1e27);
        PoolKey memory k = poolKey(address(orb), address(usdA));
        manager.initialize(k, SQRT_PRICE_1_1);
        (bool orbital,,) = hook.pools(k.toId());
        assertFalse(orbital);
    }

    function test_initializeRefusedWhilePaused() public {
        vm.prank(owner);
        hook.pause();
        MockERC20 orb = new MockERC20("Orbital", "ORB", 1e27);
        vm.expectRevert();
        manager.initialize(poolKey(address(orb), address(usdA)), SQRT_PRICE_1_1);
    }

    function test_constructorRejectsBadConfig() public {
        uint256[] memory ks = new uint256[](1);
        ks[0] = K_WIDE;
        address[] memory one = new address[](1);
        one[0] = address(usdA);
        vm.expectRevert(OrbitalHook.InvalidTokens.selector);
        deployRaw(one, ks, FEE_PPM);

        uint256[] memory badK = new uint256[](1);
        badK[0] = 2e18; // above full range for N = 3
        vm.expectRevert(OrbitalHook.InvalidLevels.selector);
        deployRaw(basket, badK, FEE_PPM);

        badK[0] = 0.7e18; // below √3 − 1
        vm.expectRevert(OrbitalHook.InvalidLevels.selector);
        deployRaw(basket, badK, FEE_PPM);

        uint256[] memory unsorted = new uint256[](2);
        unsorted[0] = K_WIDE;
        unsorted[1] = K_TIGHT;
        vm.expectRevert(OrbitalHook.InvalidLevels.selector);
        deployRaw(basket, unsorted, FEE_PPM);

        vm.expectRevert(OrbitalHook.FeeTooHigh.selector);
        deployRaw(basket, ks, 10_001);

        address[] memory dup = new address[](2);
        dup[0] = address(usdA);
        dup[1] = address(usdA);
        vm.expectRevert(OrbitalHook.InvalidTokens.selector);
        deployRaw(dup, ks, FEE_PPM);

        uint8[] memory badDecs = new uint8[](3);
        badDecs[0] = 19;
        vm.expectRevert(OrbitalHook.InvalidTokens.selector);
        deployRawDecimals(basket, badDecs, ks, FEE_PPM);
        vm.expectRevert(OrbitalHook.InvalidTokens.selector);
        deployRawDecimals(basket, new uint8[](2), ks, FEE_PPM);

        vm.expectRevert(OrbitalHook.ZeroAddress.selector);
        new OrbitalHook(IPoolManager(address(manager)), address(0), guardian, basket, new uint8[](3), ks, FEE_PPM);
    }

    // ---- liquidity --------------------------------------------------------------------------

    function test_firstDepositOpensAtEqualPrice() public {
        uint256[] memory amounts = depositAs(lp, WIDE, R);
        // Equal-price point: xᵢ = r(1 − 1/√3) ≈ 0.42265 r, and the full-range tick has no floor.
        uint256 expected = R - R * 1e18 / hook.sqrtN();
        assertCloseBps(amounts[0], expected, 1, "usdA");
        assertCloseBps(amounts[1], expected, 1, "usdB");
        assertCloseBps(amounts[2] * 1e12, expected, 1, "usdC scaled");
        assertEq(hook.totalRadius(), R);
        assertEq(hook.positions(WIDE, lp), R);
        // Tokens sit in the PoolManager, owned by the hook as claims.
        assertEq(usdA.balanceOf(address(manager)), amounts[0]);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(usdA)))), amounts[0]);
        assertApproxEqAbs(hook.invariant(), 0, 1e40, "on the sphere");
    }

    function test_concentratedTickNeedsLessCapital() public {
        uint256[] memory wide = hook.previewDeposit(WIDE, R);
        uint256[] memory tight = hook.previewDeposit(TIGHT, R);
        assertLt(tight[0], wide[0], "tight tick deposits less per unit radius");
        assertLt(tight[0] * 10, wide[0] * 6, "much less");
        // And actually depositing it works and the pool is consistent.
        depositAs(lp, TIGHT, R);
        assertEq(hook.realReserves()[0], tight[0]);
    }

    function test_depositRespectsMaxAmounts() public {
        uint256[] memory maxes = hook.previewDeposit(WIDE, R);
        maxes[1] -= 1;
        vm.prank(lp);
        vm.expectRevert(OrbitalHook.SlippageExceeded.selector);
        hook.deposit(WIDE, R, maxes);
    }

    function test_depositRejectsBadInputs() public {
        vm.startPrank(lp);
        vm.expectRevert(OrbitalHook.InvalidLevel.selector);
        hook.deposit(7, R, maxAmounts());
        vm.expectRevert(OrbitalHook.RadiusTooSmall.selector);
        hook.deposit(WIDE, 1, maxAmounts());
        vm.expectRevert(OrbitalHook.LengthMismatch.selector);
        hook.deposit(WIDE, R, new uint256[](2));
        uint256 cap = hook.MAX_TOTAL_RADIUS();
        vm.expectRevert(OrbitalHook.RadiusCapExceeded.selector);
        hook.deposit(WIDE, cap + 1, maxAmounts());
        vm.stopPrank();
    }

    function test_withdrawReturnsDeposit() public {
        uint256[] memory put = depositAs(lp, WIDE, R);
        depositAs(lp, TIGHT, R);
        uint256 a0 = usdA.balanceOf(lp);
        vm.prank(lp);
        uint256[] memory got = hook.withdraw(WIDE, R, zeros());
        assertLe(got[0], put[0]);
        assertCloseBps(put[0], got[0], 1, "usdA back");
        assertCloseBps(put[2], got[2], 1, "usdC back");
        assertEq(usdA.balanceOf(lp), a0 + got[0]);
        assertEq(hook.positions(WIDE, lp), 0);
        assertEq(hook.totalRadius(), R);
    }

    function test_withdrawEverythingLeavesOnlyDust() public {
        depositAs(lp, WIDE, R);
        depositAs(lp, TIGHT, R);
        swapAs(trader, keyAB, isZeroForOne(keyAB, address(usdA)), -50_000e18);
        vm.startPrank(lp);
        hook.withdraw(TIGHT, R, zeros());
        hook.withdraw(WIDE, R, zeros());
        hook.collectFees(TIGHT);
        hook.collectFees(WIDE);
        vm.stopPrank();
        assertEq(hook.totalRadius(), 0);
        // Whatever remains in the manager is rounding dust.
        assertLt(usdA.balanceOf(address(manager)), 1e12);
        assertLt(usdB.balanceOf(address(manager)), 1e12);
        assertLt(usdC.balanceOf(address(manager)), 10);
    }

    function test_withdrawRejectsTooMuchAndSlippage() public {
        depositAs(lp, WIDE, R);
        vm.startPrank(lp);
        vm.expectRevert(OrbitalHook.InsufficientPosition.selector);
        hook.withdraw(WIDE, R + 1, zeros());
        uint256[] memory mins = maxAmounts();
        vm.expectRevert(OrbitalHook.SlippageExceeded.selector);
        hook.withdraw(WIDE, R, mins);
        vm.expectRevert(OrbitalHook.ZeroAmount.selector);
        hook.withdraw(WIDE, 0, zeros());
        vm.stopPrank();
    }

    function test_v4LiquidityRefusedOnOrbitalPools() public {
        vm.expectRevert();
        lpRouter.modifyLiquidity(keyAB, ModifyLiquidityParams(-60, 60, 1e18, bytes32(0)), "");
    }

    // ---- swaps ------------------------------------------------------------------------------

    function test_swapExactInNearPeg() public {
        seed();
        uint256 amountIn = 1_000e18;
        bool z = isZeroForOne(keyAB, address(usdA));
        uint256 bBefore = usdB.balanceOf(trader);
        uint256 aBefore = usdA.balanceOf(trader);
        uint256 quoted = hook.quoteExactInput(address(usdA), address(usdB), amountIn);

        swapAs(trader, keyAB, z, -int256(amountIn));

        uint256 out = usdB.balanceOf(trader) - bBefore;
        assertEq(aBefore - usdA.balanceOf(trader), amountIn, "paid exactly the input");
        assertEq(out, quoted, "quote matches execution");
        // Near the peg the price is ~1 minus the fee. On the sphere the price impact of a trade of
        // size Δ is about Δ / (r_int·(1 − 1/√N)·√N) ≈ Δ / (0.577·r_int): ~6 bps here.
        uint256 netIn = amountIn - amountIn * FEE_PPM / 1_000_000;
        assertLt(out, netIn, "pays a spread");
        assertCloseBps(netIn, out, 10, "within 10 bps of par");
        assertApproxEqAbs(hook.invariant(), 0, 1e42, "on the torus");
    }

    function test_swapExactOut() public {
        seed();
        uint256 want = 1_000e6; // usdC, 6 decimals
        bool z = isZeroForOne(keyAC, address(usdA));
        uint256 quoted = hook.quoteExactOutput(address(usdA), address(usdC), want);
        uint256 aBefore = usdA.balanceOf(trader);
        uint256 cBefore = usdC.balanceOf(trader);

        swapAs(trader, keyAC, z, int256(want));

        assertEq(usdC.balanceOf(trader) - cBefore, want, "received exactly the output");
        uint256 paid = aBefore - usdA.balanceOf(trader);
        assertEq(paid, quoted, "quote matches execution");
        assertGt(paid, 1_000e18, "input covers output plus fee");
        assertCloseBps(paid, 1_000e18 + 1_000e18 * uint256(FEE_PPM) / 1_000_000, 10, "near par");
    }

    function test_swapSixDecimalsBothWays() public {
        seed();
        uint256 cBefore = usdC.balanceOf(trader);
        swapAs(trader, keyAC, isZeroForOne(keyAC, address(usdA)), -10_000e18);
        uint256 got = usdC.balanceOf(trader) - cBefore;
        assertCloseBps(10_000e6, got, 100, "usdC out in 6 decimals (about 60 bps impact on 3M radius)");

        uint256 aBefore = usdA.balanceOf(trader);
        swapAs(trader, keyAC, isZeroForOne(keyAC, address(usdC)), -int256(got));
        uint256 back = usdA.balanceOf(trader) - aBefore;
        assertLt(back, 10_000e18, "round trip loses fees + spread");
        assertCloseBps(10_000e18, back, 200, "but not much");
    }

    function test_roundTripNeverProfits() public {
        seed();
        uint256 a0 = usdA.balanceOf(trader);
        uint256 b0 = usdB.balanceOf(trader);
        bool z = isZeroForOne(keyAB, address(usdA));
        swapAs(trader, keyAB, z, -200_000e18);
        uint256 got = usdB.balanceOf(trader) - b0;
        swapAs(trader, keyAB, !z, -int256(got));
        assertLt(usdA.balanceOf(trader), a0, "trader lost value");
        assertEq(usdB.balanceOf(trader), b0);
    }

    function test_feesAccrueToLpsAndAreCollectable() public {
        seed();
        bool z = isZeroForOne(keyAB, address(usdA));
        swapAs(trader, keyAB, z, -100_000e18);
        uint256 idxA = hook.tokenIndex(address(usdA)) - 1;
        uint256[] memory pending = hook.pendingFees(TIGHT, lp);
        // Fees are split by radius: the tight level holds a third of it.
        assertCloseBps(pending[idxA], 100_000e18 * uint256(FEE_PPM) / 1_000_000 / 3, 1, "a third of the fee");
        uint256 before = usdA.balanceOf(lp);
        vm.prank(lp);
        uint256[] memory got = hook.collectFees(TIGHT);
        assertEq(got[idxA], pending[idxA]);
        assertEq(usdA.balanceOf(lp), before + got[idxA]);
        assertEq(hook.pendingFees(TIGHT, lp)[idxA], 0);
    }

    function test_swapTooLargeReverts() public {
        depositAs(lp, WIDE, R);
        // Draining more than the real reserve of the output token cannot be priced.
        vm.expectRevert();
        swapAs(trader, keyAB, isZeroForOne(keyAB, address(usdA)), -5_000_000e18);
    }

    function test_swapRevertsWithoutLiquidity() public {
        vm.expectRevert();
        swapAs(trader, keyAB, true, -1e18);
    }

    // ---- ticks & depeg isolation ------------------------------------------------------------

    function test_largeTradePinsTightTickAndUnpinsOnReturn() public {
        seed();
        assertEq(hook.boundaryMask(), 0);
        bool z = isZeroForOne(keyAB, address(usdA));
        int256 before = hook.alphaIntNorm();

        vm.expectEmit(true, false, false, true, address(hook));
        emit OrbitalHook.LevelCrossed(TIGHT, true);
        swapAs(trader, keyAB, z, -600_000e18); // dump a lot of A for B

        assertEq(hook.boundaryMask(), 1 << TIGHT, "tight tick pinned");
        assertGt(hook.alphaIntNorm(), before, "moved away from the peg");
        assertApproxEqAbs(hook.invariant(), 0, 1e42, "still on the torus after the crossing");

        // Trade back towards the peg: the tick rejoins the interior.
        uint256 bBal = usdB.balanceOf(trader);
        swapAs(trader, keyAB, !z, -int256(bBal > 550_000e18 ? 550_000e18 : bBal));
        assertEq(hook.boundaryMask(), 0, "tight tick interior again");
        assertApproxEqAbs(hook.invariant(), 0, 1e42, "on the torus after re-entry");
    }

    struct DepegSnap {
        uint256 idxA;
        uint256 idxB;
        uint256 tightA0;
        uint256 tightB0;
        uint256 wideB0;
        uint256 tightA1;
        uint256 wideA1;
        uint256 tightA2;
        uint256 wideA2;
    }

    function test_depegIsolatesConcentratedLiquidity() public {
        depositAs(lp, TIGHT, R);
        depositAs(lp, WIDE, 2 * R);
        DepegSnap memory d;
        d.idxA = hook.tokenIndex(address(usdA)) - 1;
        d.idxB = hook.tokenIndex(address(usdB)) - 1;
        d.tightA0 = hook.levelReserves(TIGHT)[d.idxA];
        d.tightB0 = hook.levelReserves(TIGHT)[d.idxB];
        d.wideB0 = hook.levelReserves(WIDE)[d.idxB];

        // usdA starts to depeg: it is dumped into the pool for usdB.
        swapAs(trader, keyAB, isZeroForOne(keyAB, address(usdA)), -300_000e18);
        assertEq(hook.boundaryMask() & (1 << TIGHT), 1 << TIGHT, "tight tick pinned to its plane");
        d.tightA1 = hook.levelReserves(TIGHT)[d.idxA];
        d.wideA1 = hook.levelReserves(WIDE)[d.idxA];

        // The depeg deepens: more usdA is dumped, now for usdC.
        swapAs(trader, keyAC, isZeroForOne(keyAC, address(usdA)), -300_000e18);
        d.tightA2 = hook.levelReserves(TIGHT)[d.idxA];
        d.wideA2 = hook.levelReserves(WIDE)[d.idxA];

        // (a) The pinned tick is isolated: its exposure to the depegging coin barely moves while
        //     the full-range tick keeps absorbing it.
        assertLt((d.tightA2 - d.tightA1) * 5, d.wideA2 - d.wideA1, "pinned tick absorbs < 1/5 of full range");
        // (b) A boundary tick's reserve of any coin is capped at r·(k/√N + s·√((N−1)/N)) per unit radius.
        uint256 cap = boundaryCap(TIGHT, R);
        assertLe(d.tightA2, cap + 1e12, "exposure stays under the geometric cap");
        assertGt(d.wideA2, 2 * cap, "full range has no such cap");
        // (c) Per unit radius, the concentrated tick lost less of the still-pegged coin.
        uint256 tightLossB = (d.tightB0 - hook.levelReserves(TIGHT)[d.idxB]) * 2; // normalise to 2R
        uint256 wideLossB = d.wideB0 - hook.levelReserves(WIDE)[d.idxB];
        assertLt(tightLossB, wideLossB, "less impermanent loss per unit of radius");
        // (d) It absorbed some usdA before pinning, but holds far less than the larger tick.
        assertGt(d.tightA2, d.tightA0, "absorbed some before pinning");
        assertLt(d.tightA2 * 2, d.wideA2, "less than half the depegged coin of a tick twice its size");

        // Everyone can still exit, paused or not.
        vm.prank(guardian);
        hook.guardianPause();
        vm.startPrank(lp);
        uint256[] memory tightGot = hook.withdraw(TIGHT, R, zeros());
        uint256[] memory wideGot = hook.withdraw(WIDE, 2 * R, zeros());
        vm.stopPrank();
        assertGt(tightGot[d.idxB], 0);
        assertGt(wideGot[d.idxB], 0);
        assertEq(hook.totalRadius(), 0);
    }

    /// @dev r·(k/√N + s·√((N−1)/N)): the most of one coin a pinned tick of radius `r` can hold.
    function boundaryCap(uint256 levelId, uint256 r) internal view returns (uint256) {
        OrbitalHook.Level memory L = hook.level(levelId);
        uint256 wMax = OrbitalMath.sqrt(uint256(2e36) / 3);
        return r * L.kNorm / 1e18 * 1e18 / hook.sqrtN() + r * L.sNorm / 1e18 * wMax / 1e18;
    }

    // ---- circuit breaker --------------------------------------------------------------------

    function test_guardianCanPauseOnlyGuardian() public {
        vm.prank(trader);
        vm.expectRevert(OrbitalHook.NotGuardian.selector);
        hook.guardianPause();
        vm.prank(owner);
        vm.expectRevert(OrbitalHook.NotGuardian.selector);
        hook.guardianPause();

        vm.prank(guardian);
        vm.expectEmit(true, false, false, true, address(hook));
        emit OrbitalHook.Paused(guardian, true);
        hook.guardianPause();
        assertTrue(hook.paused());
        // Idempotent: a second callback does not revert.
        vm.prank(guardian);
        hook.guardianPause();
    }

    function test_guardianCannotUnpause() public {
        vm.prank(guardian);
        hook.guardianPause();
        vm.prank(guardian);
        vm.expectRevert(OrbitalHook.NotOwner.selector);
        hook.unpause();
        vm.prank(owner);
        hook.unpause();
        assertFalse(hook.paused());
    }

    function test_pauseBlocksSwapsAndDepositsButNotWithdrawals() public {
        seed();
        vm.prank(guardian);
        hook.guardianPause();

        vm.expectRevert();
        swapAs(trader, keyAB, true, -1e18);
        vm.prank(lp);
        vm.expectRevert(OrbitalHook.IsPaused.selector);
        hook.deposit(WIDE, R, maxAmounts());

        vm.prank(lp);
        uint256[] memory got = hook.withdraw(WIDE, R, zeros());
        assertGt(got[0], 0, "LPs can always leave");

        vm.prank(owner);
        hook.unpause();
        swapAs(trader, keyAB, isZeroForOne(keyAB, address(usdA)), -1e18);
    }

    function test_ownerAdmin() public {
        vm.prank(trader);
        vm.expectRevert(OrbitalHook.NotOwner.selector);
        hook.setGuardian(trader);
        vm.prank(trader);
        vm.expectRevert(OrbitalHook.NotOwner.selector);
        hook.setFee(1);
        vm.prank(trader);
        vm.expectRevert(OrbitalHook.NotOwner.selector);
        hook.pause();

        vm.startPrank(owner);
        hook.setGuardian(trader);
        assertEq(hook.guardian(), trader);
        vm.expectRevert(OrbitalHook.FeeTooHigh.selector);
        hook.setFee(10_001);
        hook.setFee(1_000);
        assertEq(hook.feePpm(), 1_000);
        vm.expectRevert(OrbitalHook.ZeroAddress.selector);
        hook.transferOwnership(address(0));
        hook.transferOwnership(trader);
        vm.stopPrank();
        assertEq(hook.owner(), trader);
    }

    // ---- pass-through pools -----------------------------------------------------------------

    function test_passThroughPoolUsesPlainV4Liquidity() public {
        MockERC20 orb = new MockERC20("Orbital", "ORB", 1e27);
        orb.approve(address(lpRouter), type(uint256).max);
        orb.approve(address(swapRouter), type(uint256).max);
        PoolKey memory k = poolKey(address(orb), address(usdA));
        k.fee = 3_000;
        manager.initialize(k, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(k, ModifyLiquidityParams(-600, 600, 1_000_000e18, bytes32(0)), "");

        uint256 before = usdA.balanceOf(address(this));
        bool z = isZeroForOne(k, address(orb));
        swapAs(address(this), k, z, -1_000e18);
        assertGt(usdA.balanceOf(address(this)), before, "plain v4 swap executed");

        vm.prank(owner);
        hook.pause();
        vm.expectRevert();
        swapAs(address(this), k, z, -1_000e18);
    }

    // ---- fuzz -------------------------------------------------------------------------------

    function testFuzz_swapKeepsPointOnTorus(uint256 amountIn, bool aToB) public {
        seed();
        amountIn = bound(amountIn, 1e12, 300_000e18);
        bool z = isZeroForOne(keyAB, aToB ? address(usdA) : address(usdB));
        swapAs(trader, keyAB, z, -int256(amountIn));
        int256 f = hook.invariant();
        // |F| relative to r_int² (≈ 1e48..1e60 here): ≤ 1e-12 of it.
        (uint256 r,,) = hook.consolidated();
        assertLe(f < 0 ? uint256(-f) : uint256(f), r * r / 1e12 + 1e40, "invariant drift");
    }

    function testFuzz_roundTripNeverProfits(uint256 amountIn) public {
        seed();
        amountIn = bound(amountIn, 1e15, 400_000e18);
        bool z = isZeroForOne(keyAB, address(usdA));
        uint256 a0 = usdA.balanceOf(trader);
        uint256 b0 = usdB.balanceOf(trader);
        swapAs(trader, keyAB, z, -int256(amountIn));
        uint256 got = usdB.balanceOf(trader) - b0;
        if (got == 0) return;
        swapAs(trader, keyAB, !z, -int256(got));
        assertLe(usdA.balanceOf(trader), a0 + 10, "no free money beyond wei-level rounding");
    }

    function testFuzz_exactOutMatchesQuoteAndCostsAtLeastPar(uint256 want) public {
        seed();
        want = bound(want, 1e6, 200_000e6);
        uint256 quoted = hook.quoteExactOutput(address(usdB), address(usdC), want);
        uint256 b0 = usdB.balanceOf(trader);
        swapAs(trader, keyBC, isZeroForOne(keyBC, address(usdB)), int256(want));
        uint256 paid = b0 - usdB.balanceOf(trader);
        assertEq(paid, quoted);
        assertGe(paid, want * 1e12, "never cheaper than par near the peg");
    }
}
