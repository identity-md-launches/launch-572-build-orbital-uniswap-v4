// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {OrbitalHook} from "../../src/OrbitalHook.sol";
import {OrbitalMath} from "../../src/libraries/OrbitalMath.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {HookableERC20} from "../mocks/HookableERC20.sol";

/// @notice Harness for an arbitrary basket: deploys a PoolManager, `decs.length` mock coins, a hook
/// with the given ticks at a mined address, and initialises every pair. Complements
/// `OrbitalFixture`, whose basket is fixed.
abstract contract BasketHarness is Test {
    uint160 internal constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_ADD_LIQUIDITY
        | HookFlags.BEFORE_SWAP | HookFlags.BEFORE_SWAP_RETURN_DELTA;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    PoolManager internal manager;
    PoolSwapTest internal router;
    OrbitalHook internal hook;
    HookableERC20[] internal toks;
    address internal owner = makeAddr("owner");

    function deployBasket(uint8[] memory decs, uint256[] memory ks, uint24 fee) internal {
        manager = new PoolManager(address(this));
        router = new PoolSwapTest(manager);
        address[] memory basket = new address[](decs.length);
        for (uint256 i = 0; i < decs.length; i++) {
            HookableERC20 t = new HookableERC20(decs[i]);
            toks.push(t);
            basket[i] = address(t);
        }
        bytes memory code = abi.encodePacked(
            type(OrbitalHook).creationCode,
            abi.encode(IPoolManager(address(manager)), owner, address(0), basket, decs, ks, fee)
        );
        bytes32 salt = mine(code);
        hook = new OrbitalHook{salt: salt}(IPoolManager(address(manager)), owner, address(0), basket, decs, ks, fee);
        for (uint256 i = 0; i < basket.length; i++) {
            for (uint256 j = i + 1; j < basket.length; j++) {
                manager.initialize(key(basket[i], basket[j]), SQRT_PRICE_1_1);
            }
        }
    }

    function key(address x, address y) internal view returns (PoolKey memory) {
        (address c0, address c1) = x < y ? (x, y) : (y, x);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, 60, IHooks(address(hook)));
    }

    /// @dev Negative `amount` = exact input, positive = exact output.
    function swap(address who, address tokenIn, address tokenOut, int256 amount) internal {
        PoolKey memory k = key(tokenIn, tokenOut);
        bool z = Currency.unwrap(k.currency0) == tokenIn;
        vm.prank(who);
        router.swap(
            k,
            SwapParams(z, amount, z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function trySwap(address who, address tokenIn, address tokenOut, int256 amount)
        internal
        returns (bool ok, bytes memory ret)
    {
        PoolKey memory k = key(tokenIn, tokenOut);
        bool z = Currency.unwrap(k.currency0) == tokenIn;
        vm.prank(who);
        (ok, ret) = address(router)
            .call(
                abi.encodeCall(
                    router.swap,
                    (
                        k,
                        SwapParams(z, amount, z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                        PoolSwapTest.TestSettings(false, false),
                        ""
                    )
                )
            );
    }

    function maxes() internal view returns (uint256[] memory m) {
        m = new uint256[](toks.length);
        for (uint256 i = 0; i < m.length; i++) {
            m[i] = type(uint256).max;
        }
    }

    function zeros() internal view returns (uint256[] memory m) {
        m = new uint256[](toks.length);
    }

    function fund(address who) internal {
        for (uint256 i = 0; i < toks.length; i++) {
            toks[i].mint(who, 1e9 * 10 ** toks[i].decimals());
            vm.startPrank(who);
            toks[i].approve(address(hook), type(uint256).max);
            toks[i].approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function deposit(address who, uint256 l, uint256 r) internal returns (uint256[] memory) {
        vm.prank(who);
        return hook.deposit(l, r, maxes());
    }

    function withdraw(address who, uint256 l, uint256 r) internal returns (uint256[] memory) {
        vm.prank(who);
        return hook.withdraw(l, r, zeros());
    }

    function claimId(uint256 i) internal view returns (uint256) {
        return uint256(uint160(address(toks[i])));
    }

    /// @dev State checks every valid pool state satisfies: the point is on the torus (relative to
    /// r_int²), ‖w‖ covers the pinned ticks' circle radii, and every tick's recorded status agrees
    /// with the interior position up to `tol` (WAD units of normalised position).
    function assertConsistent(uint256 tol, string memory what) internal view {
        (uint256 r, uint256 kb, uint256 sb) = hook.consolidated();
        if (r == 0) return;
        int256 f = hook.invariant();
        assertLe(f < 0 ? uint256(-f) : uint256(f), r * r / 1e12 + 1e40, string.concat(what, ": invariant"));
        uint256[] memory x = hook.reserves();
        uint256 s;
        uint256 q;
        for (uint256 k = 0; k < x.length; k++) {
            s += x[k];
            q += x[k] * x[k];
        }
        assertGe(OrbitalMath.wNorm(s, q, x.length) + 1e6, sb, string.concat(what, ": w covers s_bound"));
        int256 a = hook.alphaIntNorm();
        uint256 mask = hook.boundaryMask();
        for (uint256 l = 0; l < hook.levelCount(); l++) {
            OrbitalHook.Level memory L = hook.level(l);
            if (L.radius == 0) continue;
            if (mask & (1 << l) != 0) {
                assertLe(int256(L.kNorm), a + int256(tol), string.concat(what, ": pinned tick above position"));
            } else {
                assertGe(int256(L.kNorm) + int256(tol), a, string.concat(what, ": interior tick below position"));
            }
        }
        kb;
    }

    /// @dev Interior reserve per coin, `u_k = x_k − x_bound,k` with
    /// `x_bound,k = k_bound/√N + s_bound·(x_k − S/N)/‖w‖` (the hook's own formula), and `r_int`.
    function interior() internal view returns (int256[] memory u, uint256 r) {
        uint256[] memory x = hook.reserves();
        uint256 kb;
        uint256 sb;
        (r, kb, sb) = hook.consolidated();
        uint256 s;
        uint256 q;
        for (uint256 k = 0; k < x.length; k++) {
            s += x[k];
            q += x[k] * x[k];
        }
        uint256 w = OrbitalMath.wNorm(s, q, x.length);
        uint256 sqrtN = hook.sqrtN();
        u = new int256[](x.length);
        for (uint256 k = 0; k < x.length; k++) {
            int256 xb = int256(kb * 1e18 / sqrtN);
            if (w != 0) xb += int256(sb) * (int256(x[k]) - int256(s / x.length)) / int256(w);
            u[k] = int256(x[k]) - xb;
        }
    }

    /// @dev No coin's interior reserve lies past the sphere's pole (`u_k ≤ r_int`, price ≥ 0), and
    /// the point is not inside the torus by more than the hook's start-of-trade tolerance, so the
    /// pool is never left in a state it would refuse to trade from.
    function assertBelowPoles(string memory what) internal view {
        (int256[] memory u, uint256 r) = interior();
        if (r == 0) return;
        for (uint256 k = 0; k < u.length; k++) {
            assertLe(u[k], int256(r) + 1e6, string.concat(what, ": coin past its pole"));
        }
        uint256 maxScale = 1;
        for (uint256 k = 0; k < toks.length; k++) {
            uint256 sc = 10 ** (18 - toks[k].decimals());
            if (sc > maxScale) maxScale = sc;
        }
        int256 f = hook.invariant();
        assertGe(f, -int256(r * (r / 1e6) + 4 * r * maxScale), string.concat(what, ": inside the torus"));
    }

    function mine(bytes memory code) internal view returns (bytes32) {
        bytes32 h = keccak256(code);
        for (uint256 i = 0; i < 500_000; i++) {
            address p =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), h)))));
            if (HookFlags.matches(p, FLAGS)) return bytes32(i);
        }
        revert("no salt");
    }
}
