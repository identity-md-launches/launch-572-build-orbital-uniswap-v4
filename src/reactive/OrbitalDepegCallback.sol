// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPayer} from "./IReactive.sol";

interface IOrbitalGuardian {
    function guardianPause() external;
    function paused() external view returns (bool);
}

/// @title OrbitalDepegCallback
/// @notice Destination-chain half of the depeg circuit breaker (Unichain Sepolia, 1301).
/// The Reactive callback proxy invokes `depeg(...)`; this contract verifies the caller and the
/// RVM id, then pauses the Orbital hook through its guardian role. It can only pause — resuming is
/// the hook owner's decision. A delivery for a round already acted on, or arriving while the hook
/// is already paused, is acknowledged with an event and does nothing.
///
/// The deployer is the first owner (so a deploy script can wire the hook in and then hand over);
/// `hook` may be left zero at construction and set once with `setHook`, which lets the hook be
/// deployed with this contract's address as its guardian from the start.
contract OrbitalDepegCallback is IPayer {
    address public owner;
    /// @notice Reactive Network callback proxy on this chain (the only allowed caller of `depeg`).
    address public immutable callbackProxy;
    /// @notice The hook whose guardian this contract is. Set once.
    IOrbitalGuardian public hook;
    /// @notice RVM id = the EOA that deployed `OrbitalDepegReactive`. Zero disables the check
    /// until set (depeg reverts).
    address public rvmId;
    /// @notice Highest Chainlink round acted on, per aggregator (rounds restart on rotation).
    mapping(address => uint256) public lastRoundId;

    event DepegPauseTriggered(address indexed feed, int256 price, uint256 roundId);
    event DepegAlreadyPaused(address indexed feed, int256 price, uint256 roundId);
    event StaleRoundIgnored(address indexed feed, int256 price, uint256 roundId);
    event HookSet(address indexed hook);
    event RvmIdUpdated(address indexed rvmId);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotCallbackProxy();
    error WrongRvmId();
    error ZeroAddress();
    error HookAlreadySet();
    error HookNotSet();
    error PaymentFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _callbackProxy, address _hook, address _rvmId) payable {
        if (_callbackProxy == address(0)) revert ZeroAddress();
        callbackProxy = _callbackProxy;
        hook = IOrbitalGuardian(_hook);
        rvmId = _rvmId;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        emit HookSet(_hook);
        emit RvmIdUpdated(_rvmId);
    }

    /// @notice Entry point for the Reactive callback. `_rvmId` is injected by the callback proxy.
    function depeg(address _rvmId, address feed, int256 price, uint256 roundId) external {
        if (msg.sender != callbackProxy) revert NotCallbackProxy();
        if (_rvmId == address(0) || _rvmId != rvmId) revert WrongRvmId();
        if (address(hook) == address(0)) revert HookNotSet();
        if (roundId <= lastRoundId[feed]) {
            emit StaleRoundIgnored(feed, price, roundId);
            return;
        }
        lastRoundId[feed] = roundId;
        if (hook.paused()) {
            emit DepegAlreadyPaused(feed, price, roundId);
            return;
        }
        hook.guardianPause();
        emit DepegPauseTriggered(feed, price, roundId);
    }

    /// @notice One-shot: binds the hook this contract guards when it was not known at construction.
    function setHook(address _hook) external onlyOwner {
        if (_hook == address(0)) revert ZeroAddress();
        if (address(hook) != address(0)) revert HookAlreadySet();
        hook = IOrbitalGuardian(_hook);
        emit HookSet(_hook);
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
