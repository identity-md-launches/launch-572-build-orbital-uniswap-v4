// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OrbitalMath} from "../src/libraries/OrbitalMath.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract OrbitalMathTest is Test {
    uint256 constant WAD = 1e18;

    function testFuzz_sqrtIsFloor(uint256 x) public pure {
        uint256 r = OrbitalMath.sqrt(x);
        assertLe(r * r, x);
        if (r < type(uint128).max) assertGt((r + 1) * (r + 1), x);
    }

    function test_sqrtN() public pure {
        assertEq(OrbitalMath.sqrtN(4), 2e18);
        assertEq(OrbitalMath.sqrtN(2), 1414213562373095048);
        assertEq(OrbitalMath.sqrtN(3), 1732050807568877293);
    }

    function test_tickGeometry() public pure {
        uint256 n = 3;
        uint256 s3 = OrbitalMath.sqrtN(n);
        uint256 kMax = (n - 1) * WAD * WAD / s3;
        // Full-range tick: s = √((N−1)/N) and the floor is zero.
        uint256 sFull = OrbitalMath.sNorm(kMax, s3);
        assertApproxEqRel(sFull, OrbitalMath.sqrt((n - 1) * WAD * WAD / n), 1e9);
        assertLe(OrbitalMath.xMinNorm(kMax, sFull, n, s3), 1e6);
        // Tightest tick: s → 0 and the floor is the equal-price reserve r(1 − 1/√N).
        uint256 kMin = s3 - WAD + 1;
        uint256 sMin = OrbitalMath.sNorm(kMin, s3);
        assertLt(sMin, 2e9);
        assertApproxEqRel(OrbitalMath.xMinNorm(kMin, sMin, n, s3), WAD - WAD * WAD / s3, 1e11);
    }

    function test_invariantZeroAtEqualPoint() public pure {
        uint256 n = 3;
        uint256 s3 = OrbitalMath.sqrtN(n);
        uint256 r = 1_000_000e18;
        uint256 each = (r * s3 / WAD - r) * s3 / WAD / n;
        uint256 s = n * each;
        uint256 q = n * each * each;
        int256 f = OrbitalMath.invariant(s, q, n, s3, OrbitalMath.Consolidated(r, 0, 0));
        // |F| far below r² (1e60)
        assertLt(f < 0 ? uint256(-f) : uint256(f), 1e44);
        assertApproxEqRel(uint256(OrbitalMath.alphaIntNorm(s, s3, OrbitalMath.Consolidated(r, 0, 0))), s3 - WAD, 1e9);
    }

    function testFuzz_solveOutLandsOnSphere(uint256 dIn) public pure {
        uint256 n = 3;
        uint256 s3 = OrbitalMath.sqrtN(n);
        uint256 r = 1_000_000e18;
        uint256 each = (r * s3 / WAD - r) * s3 / WAD / n;
        dIn = bound(dIn, 1e9, each / 2);
        OrbitalMath.Pair memory p = OrbitalMath.Pair(each, each, 3 * each, 3 * each * each);
        OrbitalMath.Consolidated memory c = OrbitalMath.Consolidated(r, 0, 0);
        uint256 dOut = OrbitalMath.solveOut(p, dIn, each, n, s3, c);
        assertLt(dOut, dIn, "output below input at the equal point");
        assertGt(dOut * 2, dIn, "price impact bounded: even half the reserve trades above 0.5");
        if (dIn < each / 100) assertGt(dOut * 100, dIn * 98, "small trades are within 2% of par");
        uint256 xi = each + dIn;
        uint256 xj = each - dOut;
        uint256 q = xi * xi + xj * xj + each * each;
        int256 f = OrbitalMath.invariant(xi + xj + each, q, n, s3, c);
        assertLe(f, 0, "pool-favourable rounding stays inside");
        assertLt(uint256(-f), r * r / 1e15 + 1e40, "but essentially on the surface");
    }

    function testFuzz_solveInInvertsSolveOut(uint256 dIn) public pure {
        uint256 n = 3;
        uint256 s3 = OrbitalMath.sqrtN(n);
        uint256 r = 1_000_000e18;
        uint256 each = (r * s3 / WAD - r) * s3 / WAD / n;
        dIn = bound(dIn, 1e12, each / 3);
        OrbitalMath.Pair memory p = OrbitalMath.Pair(each, each, 3 * each, 3 * each * each);
        OrbitalMath.Consolidated memory c = OrbitalMath.Consolidated(r, 0, 0);
        uint256 dOut = OrbitalMath.solveOut(p, dIn, each, n, s3, c);
        uint256 back = OrbitalMath.solveIn(p, dOut, r, n, s3, c);
        assertLe(back, dIn + 2, "exact-out input never exceeds the exact-in input by more than rounding");
        assertGe(back + dIn / 1e9 + 2, dIn, "and matches it closely");
    }

    function test_solveOutRevertsWhenDrained() public {
        uint256 n = 3;
        uint256 s3 = OrbitalMath.sqrtN(n);
        uint256 r = 1_000_000e18;
        uint256 each = (r * s3 / WAD - r) * s3 / WAD / n;
        OrbitalMath.Pair memory p = OrbitalMath.Pair(each, each, 3 * each, 3 * each * each);
        OrbitalMath.Consolidated memory c = OrbitalMath.Consolidated(r, 0, 0);
        // A real trade whose output bound is too small to reach the surface cannot be solved.
        vm.expectRevert(OrbitalMath.InsufficientLiquidity.selector);
        this.solveOutExternal(p, each / 2, 1_000, n, s3, c);
        // Past the pole the solver reports no output; the hook's pole check rejects the trade.
        assertEq(OrbitalMath.solveOut(p, 3 * r, each, n, s3, c), 0);
        // Exact-out beyond the reserve, or beyond what any input can buy, is refused.
        vm.expectRevert(OrbitalMath.InsufficientLiquidity.selector);
        this.solveInExternal(p, each + 1, r, n, s3, c);
        vm.expectRevert(OrbitalMath.InsufficientLiquidity.selector);
        this.solveInExternal(p, each - 1, r / 10, n, s3, c);
    }

    function solveOutExternal(
        OrbitalMath.Pair memory p,
        uint256 dIn,
        uint256 maxOut,
        uint256 n,
        uint256 s3,
        OrbitalMath.Consolidated memory c
    ) external pure returns (uint256) {
        return OrbitalMath.solveOut(p, dIn, maxOut, n, s3, c);
    }

    function solveInExternal(
        OrbitalMath.Pair memory p,
        uint256 dOut,
        uint256 maxIn,
        uint256 n,
        uint256 s3,
        OrbitalMath.Consolidated memory c
    ) external pure returns (uint256) {
        return OrbitalMath.solveIn(p, dOut, maxIn, n, s3, c);
    }

    function test_planeStepStaysPutAtZeroShift() public pure {
        uint256 each = 1e24;
        OrbitalMath.Pair memory p = OrbitalMath.Pair(each, each, 3 * each, 3 * each * each);
        (bool ok, uint256 t, uint256 dOut) = OrbitalMath.tryPlaneStep(p, p.s, p.q, false);
        assertTrue(ok);
        assertEq(t, 0);
        assertEq(dOut, 0);
        (ok, t, dOut) = OrbitalMath.tryPlaneStep(p, p.s, p.q, true);
        assertTrue(ok);
        assertEq(t, 0);
    }

    function test_planeStepPicksTheRequestedImage() public pure {
        // j-heavy start: x_i = 0.9e24, x_j = 1.1e24, third coin at 1e24. Target the plane with the
        // same S and Q as the current point: the j-heavy image is here (t = 0), the i-heavy image is
        // the mirror (x_i and x_j swapped, t = 0.2e24).
        OrbitalMath.Pair memory p = OrbitalMath.Pair(0.9e24, 1.1e24, 3e24, 0.81e48 + 1.21e48 + 1e48);
        (bool ok, uint256 t, uint256 dOut) = OrbitalMath.tryPlaneStep(p, p.s, p.q, false);
        assertTrue(ok);
        assertEq(t, 0);
        assertEq(dOut, 0);
        (ok, t, dOut) = OrbitalMath.tryPlaneStep(p, p.s, p.q, true);
        assertTrue(ok);
        assertEq(t, 0.2e24);
        assertEq(dOut, 0.2e24);
        // Q = 3e48 is the least Q on this plane (x_i = x_j = 1e24): a tangent touch, reached at
        // the turning point by either image.
        (ok, t, dOut) = OrbitalMath.tryPlaneStep(p, p.s, 3e48, false);
        assertTrue(ok);
        assertEq(t, 0.1e24);
        assertEq(dOut, 0.1e24);
        // Below that the plane cannot be reached: reported, not clamped.
        (ok,,) = OrbitalMath.tryPlaneStep(p, p.s, 2.9e48, false);
        assertFalse(ok);
        (ok,,) = OrbitalMath.tryPlaneStep(p, p.s, 2.9e48, true);
        assertFalse(ok);
        // A plane behind the trade (needs x_i to shrink) is reported too.
        (ok,,) = OrbitalMath.tryPlaneStep(OrbitalMath.Pair(1.1e24, 0.9e24, 3e24, p.q), p.s, p.q, false);
        assertFalse(ok);
    }

    function test_hookFlags() public pure {
        address a = address(uint160(0xABCD << 14) | uint160(HookFlags.BEFORE_SWAP | HookFlags.BEFORE_INITIALIZE));
        assertEq(HookFlags.flagsOf(a), HookFlags.BEFORE_SWAP | HookFlags.BEFORE_INITIALIZE);
        assertTrue(HookFlags.matches(a, HookFlags.BEFORE_SWAP | HookFlags.BEFORE_INITIALIZE));
        assertFalse(HookFlags.matches(a, HookFlags.BEFORE_SWAP));
        assertEq(HookFlags.ALL, (1 << 14) - 1);
    }
}
