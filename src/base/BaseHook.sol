// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title BaseHook
/// @notice Minimal Uniswap v4 hook base for a hook that implements `beforeInitialize`,
/// `beforeAddLiquidity` and `beforeSwap`: those callbacks are restricted to the PoolManager and
/// forwarded to internal `_` variants. Every other `IHooks` callback (and any other unknown
/// selector) lands in the fallback and reverts `HookNotImplemented`. The PoolManager only calls
/// the callbacks whose bits are set in the hook's address, so nothing else is ever reached; keeping
/// the unused callbacks out of the dispatcher keeps the hook's runtime under the EIP-170 limit.
/// @dev Written for this project (after the v4-periphery pattern) so the hook has no external
/// library dependency beyond v4-core. The constructor checks that the deployed address carries
/// exactly the permission bits that `getHookPermissions` declares.
abstract contract BaseHook {
    error NotPoolManager();
    error HookNotImplemented();

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice The callbacks this hook implements. Must agree with the bits of its address.
    function getHookPermissions() public pure virtual returns (Hooks.Permissions memory);

    /// @dev Any `IHooks` callback this hook does not implement, or any other unknown call.
    fallback() external {
        revert HookNotImplemented();
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        return _beforeInitialize(sender, key, sqrtPriceX96);
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4) {
        return _beforeAddLiquidity(sender, key, params, hookData);
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return _beforeSwap(sender, key, params, hookData);
    }

    function _beforeInitialize(address, PoolKey calldata, uint160) internal virtual returns (bytes4);

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        returns (bytes4);

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        virtual
        returns (bytes4, BeforeSwapDelta, uint24);
}
