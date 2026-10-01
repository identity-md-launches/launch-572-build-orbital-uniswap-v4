// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title OrbitalMath
/// @notice Fixed-point geometry for Paradigm's Orbital stableswap.
/// @dev All reserves are 18-decimal fixed point ("WAD") and live in *virtual* coordinates: the
/// point `x` on the N-dimensional sphere, including the reserves a concentrated tick never has to
/// hold. Notation follows the paper:
///
///   v        = (1, …, 1) / √N                      the equal-price direction
///   α        = x · v = S / √N                      component along v (S = Σ xᵢ)
///   ‖w‖      = √(Q − S²/N)                         component orthogonal to v (Q = Σ xᵢ²)
///   r_int    = Σ radii of interior ticks           consolidated interior sphere
///   k_bound  = Σ k of boundary ticks               consolidated boundary plane
///   s_bound  = Σ s of boundary ticks               consolidated boundary circle radius
///
/// and the global invariant is the torus
///
///   (α − k_bound − r_int·√N)² + (‖w‖ − s_bound)² = r_int².
///
/// Ticks are parameterised per unit radius: k_norm = k / r ∈ (√N − 1, (N−1)/√N] and
/// s_norm = √(1 − (√N − k_norm)²). A tick is interior while the interior's normalised position
/// α_int / r_int is below its k_norm, and pinned to its plane (boundary) once above it.
///
/// α is not monotonic along a trade: adding token i and removing token j lowers α while xᵢ < xⱼ
/// and raises it afterwards (the marginal price is 1 exactly at xᵢ = xⱼ). The interior can only
/// reach its own equal-price point (‖w‖ = s_bound) once every tick has rejoined it, because each
/// k_norm exceeds √N − 1, so ‖w‖ ≥ s_bound holds on every valid state.
///
/// Everything is `internal` on purpose: the hook's runtime must contain no DELEGATECALL.
library OrbitalMath {
    uint256 internal constant WAD = 1e18;

    error InsufficientLiquidity();
    error MathOverflow();

    struct Consolidated {
        uint256 r; // interior radius sum (WAD)
        uint256 kb; // boundary k sum (WAD)
        uint256 sb; // boundary s sum (WAD)
    }

    /// @notice Floor square root.
    function sqrt(uint256 a) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 result = 1 << (log2(a) >> 1);
        unchecked {
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            return result < a / result ? result : a / result;
        }
    }

    function log2(uint256 value) internal pure returns (uint256 result) {
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 128;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 64;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 32;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 16;
            }
            if (value >> 8 > 0) {
                value >>= 8;
                result += 8;
            }
            if (value >> 4 > 0) {
                value >>= 4;
                result += 4;
            }
            if (value >> 2 > 0) {
                value >>= 2;
                result += 2;
            }
            if (value >> 1 > 0) result += 1;
        }
    }

    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @notice √N in WAD.
    function sqrtN(uint256 n) internal pure returns (uint256) {
        return sqrt(n * WAD * WAD);
    }

    /// @notice s_norm = √(1 − (√N − k_norm)²) in WAD. Reverts if k_norm is out of range.
    function sNorm(uint256 kNorm, uint256 sqrtNWad) internal pure returns (uint256) {
        if (kNorm >= sqrtNWad) revert MathOverflow();
        uint256 d = sqrtNWad - kNorm;
        uint256 d2 = d * d / WAD;
        if (d2 > WAD) revert MathOverflow();
        return sqrt((WAD - d2) * WAD);
    }

    /// @notice Minimum reserve of any single token per unit radius for a tick with `kNorm`:
    /// x_min = k/√N − s·√((N−1)/N). This is the amount a concentrated LP never has to deposit.
    function xMinNorm(uint256 kNorm, uint256 sNormWad, uint256 n, uint256 sqrtNWad) internal pure returns (uint256) {
        uint256 kOverSqrtN = kNorm * WAD / sqrtNWad;
        uint256 wMax = sqrt((n - 1) * WAD * WAD / n); // √((N−1)/N) in WAD
        uint256 sub = sNormWad * wMax / WAD;
        return kOverSqrtN > sub ? kOverSqrtN - sub : 0;
    }

    /// @notice α = S / √N.
    function alpha(uint256 s, uint256 sqrtNWad) internal pure returns (uint256) {
        return s * WAD / sqrtNWad;
    }

    /// @notice ‖w‖ = √(Q − S²/N).
    function wNorm(uint256 s, uint256 q, uint256 n) internal pure returns (uint256) {
        uint256 a2 = s * s / n;
        return sqrt(q > a2 ? q - a2 : 0);
    }

    /// @notice The torus invariant F; zero on the surface, negative inside, positive outside.
    function invariant(uint256 s, uint256 q, uint256 n, uint256 sqrtNWad, Consolidated memory c)
        internal
        pure
        returns (int256)
    {
        int256 a = int256(alpha(s, sqrtNWad)) - int256(c.kb) - int256(c.r * sqrtNWad / WAD);
        int256 b = int256(wNorm(s, q, n)) - int256(c.sb);
        return a * a + b * b - int256(c.r * c.r);
    }

    /// @notice Normalised position of the consolidated interior: (α − k_bound) / r_int, in WAD.
    function alphaIntNorm(uint256 s, uint256 sqrtNWad, Consolidated memory c) internal pure returns (int256) {
        return (int256(alpha(s, sqrtNWad)) - int256(c.kb)) * int256(WAD) / int256(c.r);
    }

    struct Pair {
        uint256 xi; // reserve of the input token
        uint256 xj; // reserve of the output token
        uint256 s; // Σ x
        uint256 q; // Σ x²
    }

    /// @dev F after adding `dIn` to token i and removing `dOut` from token j.
    function _f(Pair memory p, uint256 dIn, uint256 dOut, uint256 n, uint256 sqrtNWad, Consolidated memory c)
        private
        pure
        returns (int256)
    {
        uint256 xi1 = p.xi + dIn;
        uint256 xj1 = p.xj - dOut;
        uint256 q1 = p.q - p.xi * p.xi - p.xj * p.xj + xi1 * xi1 + xj1 * xj1;
        return invariant(p.s + dIn - dOut, q1, n, sqrtNWad, c);
    }

    /// @notice Exact-input: the output `dOut` that keeps the point on the torus after `dIn` is
    /// added, rounded in the pool's favour. `maxOut` bounds the search (real reserve of token j).
    function solveOut(Pair memory p, uint256 dIn, uint256 maxOut, uint256 n, uint256 sqrtNWad, Consolidated memory c)
        internal
        pure
        returns (uint256)
    {
        if (_f(p, dIn, 0, n, sqrtNWad, c) >= 0) return 0; // dust: already on/outside the surface
        if (maxOut == 0 || _f(p, dIn, maxOut, n, sqrtNWad, c) < 0) revert InsufficientLiquidity();
        uint256 lo = 0;
        uint256 hi = maxOut;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) >> 1;
            if (_f(p, dIn, mid, n, sqrtNWad, c) < 0) lo = mid;
            else hi = mid;
        }
        return lo;
    }

    /// @notice Exact-output: the input `dIn` that keeps the point on the torus after `dOut` is
    /// removed, rounded in the pool's favour.
    function solveIn(Pair memory p, uint256 dOut, uint256 maxIn, uint256 n, uint256 sqrtNWad, Consolidated memory c)
        internal
        pure
        returns (uint256)
    {
        if (dOut > p.xj) revert InsufficientLiquidity();
        if (_f(p, 0, dOut, n, sqrtNWad, c) <= 0) return 0; // dust
        uint256 lo = 0;
        uint256 hi = dOut == 0 ? 1 : dOut;
        // Expand until the point is back inside; a trade past the pole never gets there.
        while (_f(p, hi, dOut, n, sqrtNWad, c) > 0) {
            lo = hi;
            hi <<= 1;
            if (hi > maxIn) revert InsufficientLiquidity();
        }
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) >> 1;
            if (_f(p, mid, dOut, n, sqrtNWad, c) > 0) lo = mid;
            else hi = mid;
        }
        return hi;
    }

    /// @notice Move along eᵢ − eⱼ inside the plane S = sT until Σx² = qT.
    /// @dev Used to land exactly on a tick boundary. The two points of the (i, j)-plane with that
    /// S and Q are mirror images (xᵢ and xⱼ swapped); `iHeavy` selects the one with xᵢ ≥ xⱼ.
    /// A trade that adds i and removes j has xᵢ increasing throughout, so a plane met before the
    /// trade's turning point (xᵢ = xⱼ, where α is minimal) is the j-heavy image and one met after
    /// it is the i-heavy image. Returns `ok = false` when the plane lies behind the trade or the
    /// path never reaches it (Q = qT unattainable); a discriminant within rounding of zero is
    /// treated as a tangent touch. `t` is the input added to token i, `dOut` the output removed
    /// from token j (`t − (sT − s)`).
    function tryPlaneStep(Pair memory p, uint256 sT, uint256 qT, bool iHeavy)
        internal
        pure
        returns (bool ok, uint256 t, uint256 dOut)
    {
        int256 cShift = int256(sT) - int256(p.s);
        int256 a = int256(p.xi);
        int256 b = int256(p.xj) + cShift;
        if (b < 0) return (false, 0, 0);
        int256 cq = int256(qT) - int256(p.q - p.xi * p.xi - p.xj * p.xj);
        int256 sumAB = a + b;
        int256 disc = 2 * cq - sumAB * sumAB;
        if (disc < 0) {
            // Rounding noise in qT is ~1e-18 of (a+b)²; anything more negative is a genuine miss.
            if (-disc > sumAB * sumAB / int256(WAD) + 1e20) return (false, 0, 0);
            disc = 0;
        }
        int256 root = int256(sqrt(uint256(disc)));
        int256 tMin = cShift > 0 ? cShift : int256(0);
        int256 chosen = iHeavy ? (b - a + root) / 2 : (b - a - root) / 2;
        if (chosen < tMin) return (false, 0, 0);
        return (true, uint256(chosen), uint256(chosen - cShift));
    }
}
