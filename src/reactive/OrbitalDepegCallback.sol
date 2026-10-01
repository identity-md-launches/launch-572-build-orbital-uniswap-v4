// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPayer} from "./IReactive.sol";

interface IOrbitalGuardian {
    function guardianPause() external;
}

/// @title OrbitalDepegCallback
/// @notice Destination-chain half of the depeg circuit breaker (Unichain Sepolia, 1301).
/// The Reactive callback proxy invokes `depeg(...)`; this contract verifies the caller and the
/// RVM id, then pauses the Orbital hook through its guardian role. It can only pause — resuming is
/// the hook owner's decision.
contract OrbitalDepegCallback is IPayer {
    address public owner;
    /// @notice Reactive Network callback proxy on this chain (the only allowed caller of `depeg`).
    address public immutable callbackProxy;
    /// @notice Address of the hook whose guardian this contract is.
    IOrbitalGuardian public immutable hook;
    /// @notice RVM id = the EOA that deployed `OrbitalDepegReactive`. Zero disables the check
    /// until set (depeg reverts).
    address public rvmId;

    event DepegPauseTriggered(address indexed feed, int256 price, uint256 roundId);
    event RvmIdUpdated(address indexed rvmId);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotCallbackProxy();
    error WrongRvmId();
    error ZeroAddress();
    error PaymentFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _callbackProxy, address _hook, address _rvmId, address _owner) payable {
        if (_callbackProxy == address(0) || _hook == address(0) || _owner == address(0)) revert ZeroAddress();
        callbackProxy = _callbackProxy;
        hook = IOrbitalGuardian(_hook);
        rvmId = _rvmId;
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
        emit RvmIdUpdated(_rvmId);
    }

    /// @notice Entry point for the Reactive callback. `_rvmId` is injected by the callback proxy.
    function depeg(address _rvmId, address feed, int256 price, uint256 roundId) external {
        if (msg.sender != callbackProxy) revert NotCallbackProxy();
        if (_rvmId == address(0) || _rvmId != rvmId) revert WrongRvmId();
        hook.guardianPause();
        emit DepegPauseTriggered(feed, price, roundId);
    }

    function setRvmId(address _rvmId) external onlyOwner {
        rvmId = _rvmId;
        emit RvmIdUpdated(_rvmId);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @inheritdoc IPayer
    /// @dev The callback proxy charges this contract for delivered callbacks; keep it funded.
    function pay(uint256 amount) external override {
        if (msg.sender != callbackProxy) revert NotCallbackProxy();
        (bool ok,) = callbackProxy.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }

    function withdraw(address payable to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }

    receive() external payable {}
}
