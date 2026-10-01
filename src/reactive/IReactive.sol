// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The subset of Reactive Network's `reactive-lib` interfaces this project needs,
/// declared locally so the audited core carries no third-party dependency.
/// Shapes follow github.com/Reactive-Network/reactive-lib (`IReactive`, `ISubscriptionService`).
interface IReactive {
    struct LogRecord {
        uint256 chain_id;
        address _contract;
        uint256 topic_0;
        uint256 topic_1;
        uint256 topic_2;
        uint256 topic_3;
        bytes data;
        uint256 block_number;
        uint256 op_code;
        uint256 block_hash;
        uint256 tx_hash;
        uint256 log_index;
    }

    /// @dev Emitted by a reactive contract to request a destination-chain call. The Reactive
    /// Network delivers `payload` to `_contract` on `chain_id` through its callback proxy, after
    /// overwriting the first 160-bit argument with the RVM id (the reactive contract's deployer).
    event Callback(uint256 indexed chain_id, address indexed _contract, uint64 indexed gas_limit, bytes payload);

    function react(LogRecord calldata log) external;
}

/// @notice Reactive Network system contract (0x0000000000000000000000000000000000fffFfF).
interface ISystemContract {
    function subscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external;

    function unsubscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external;
}

/// @notice Payment hook the Reactive Network (system contract / callback proxy) invokes to collect
/// debt from a contract it has served.
interface IPayer {
    function pay(uint256 amount) external;
}
