// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {OrbitalHook} from "../../src/OrbitalHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC20Decimals} from "../mocks/MockERC20Decimals.sol";

/// @notice Shared harness: a fresh PoolManager, three mock stablecoins (two with 18 decimals, one
/// with 6), an OrbitalHook at a mined address with a tight and a wide tick, and v4 test routers.
abstract contract OrbitalFixture is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_ADD_LIQUIDITY
        | HookFlags.BEFORE_SWAP | HookFlags.BEFORE_SWAP_RETURN_DELTA;

    uint24 internal constant FEE_PPM = 400; // 0.04%
    uint256 internal constant K_TIGHT = 0.74e18; // pins early: concentrated (√3 − 1 ≈ 0.732)
    uint256 internal constant K_MID = 0.95e18;
    uint256 internal constant K_WIDE = 1.15e18; // ≈ full range for N = 3
    uint256 internal constant TIGHT = 0;
    uint256 internal constant MID = 1;
    uint256 internal constant WIDE = 2;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    OrbitalHook internal hook;

    MockERC20 internal usdA; // 18 decimals
    MockERC20 internal usdB; // 18 decimals
    MockERC20Decimals internal usdC; // 6 decimals
    address[] internal basket;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");

    PoolKey internal keyAB;
    PoolKey internal keyAC;
    PoolKey internal keyBC;

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        usdA = new MockERC20("USD A", "USDA", 0);
        usdB = new MockERC20("USD B", "USDB", 0);
        usdC = new MockERC20Decimals("USD C", "USDC", 6);
        basket = new address[](3);
        basket[0] = address(usdA);
        basket[1] = address(usdB);
        basket[2] = address(usdC);

        uint256[] memory ks = new uint256[](3);
        ks[0] = K_TIGHT;
        ks[1] = K_MID;
        ks[2] = K_WIDE;
        hook = deployHook(owner, guardian, basket, decimalsOf(basket), ks, FEE_PPM);

        keyAB = poolKey(address(usdA), address(usdB));
        keyAC = poolKey(address(usdA), address(usdC));
        keyBC = poolKey(address(usdB), address(usdC));
        manager.initialize(keyAB, SQRT_PRICE_1_1);
        manager.initialize(keyAC, SQRT_PRICE_1_1);
        manager.initialize(keyBC, SQRT_PRICE_1_1);

        fund(lp, 100_000_000);
        fund(trader, 100_000_000);
        fund(address(this), 100_000_000);
    }

    // ---- helpers ------------------------------------------------------------------------------

    function deployHook(
        address _owner,
        address _guardian,
        address[] memory _basket,
        uint8[] memory decs,
        uint256[] memory ks,
        uint24 fee
    ) internal returns (OrbitalHook h) {
        bytes memory creationCode = abi.encodePacked(
            type(OrbitalHook).creationCode,
            abi.encode(IPoolManager(address(manager)), _owner, _guardian, _basket, decs, ks, fee)
        );
        bytes32 salt = mineSalt(address(this), creationCode, FLAGS);
        h = new OrbitalHook{salt: salt}(IPoolManager(address(manager)), _owner, _guardian, _basket, decs, ks, fee);
        assertTrue(HookFlags.matches(address(h), FLAGS), "hook address flags");
    }

    function decimalsOf(address[] memory toks) internal view returns (uint8[] memory decs) {
        decs = new uint8[](toks.length);
        for (uint256 i = 0; i < toks.length; i++) {
            (bool ok, bytes memory ret) = toks[i].staticcall(abi.encodeWithSignature("decimals()"));
            require(ok, "decimals");
            decs[i] = abi.decode(ret, (uint8));
        }
    }

    function mineSalt(address deployer, bytes memory creationCode, uint160 flags) internal pure returns (bytes32) {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 500_000; i++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initCodeHash))))
            );
            if (HookFlags.matches(predicted, flags)) return bytes32(i);
        }
        revert("no salt");
    }

    function poolKey(address a, address b) internal view returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev Gives `who` `units` whole tokens of each stablecoin and approves the hook and routers.
    function fund(address who, uint256 units) internal {
        usdA.mint(who, units * 1e18);
        usdB.mint(who, units * 1e18);
        usdC.mint(who, units * 1e6);
        vm.startPrank(who);
        usdA.approve(address(hook), type(uint256).max);
        usdB.approve(address(hook), type(uint256).max);
        usdC.approve(address(hook), type(uint256).max);
        usdA.approve(address(swapRouter), type(uint256).max);
        usdB.approve(address(swapRouter), type(uint256).max);
        usdC.approve(address(swapRouter), type(uint256).max);
        usdA.approve(address(lpRouter), type(uint256).max);
        usdB.approve(address(lpRouter), type(uint256).max);
        usdC.approve(address(lpRouter), type(uint256).max);
        vm.stopPrank();
    }

    function maxAmounts() internal pure returns (uint256[] memory m) {
        m = new uint256[](3);
        m[0] = type(uint256).max;
        m[1] = type(uint256).max;
        m[2] = type(uint256).max;
    }

    function zeros() internal pure returns (uint256[] memory m) {
        m = new uint256[](3);
    }

    function depositAs(address who, uint256 levelId, uint256 radius) internal returns (uint256[] memory amounts) {
        vm.prank(who);
        amounts = hook.deposit(levelId, radius, maxAmounts());
    }

    /// @dev Exact-input swap through the v4 router: negative `amount` = exact in, positive = exact out.
    function swapAs(address who, PoolKey memory key, bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        vm.prank(who);
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function isZeroForOne(PoolKey memory key, address tokenIn) internal pure returns (bool) {
        return Currency.unwrap(key.currency0) == tokenIn;
    }

    function balance(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok, "balanceOf");
        return abi.decode(ret, (uint256));
    }

    function sum(uint256[] memory a) internal pure returns (uint256 s) {
        for (uint256 i = 0; i < a.length; i++) {
            s += a[i];
        }
    }

    /// @dev Relative closeness: |a − b| ≤ a · bps / 10_000.
    function assertCloseBps(uint256 a, uint256 b, uint256 bps, string memory what) internal pure {
        uint256 diff = a > b ? a - b : b - a;
        assertLe(diff * 10_000, a * bps, what);
    }
}
