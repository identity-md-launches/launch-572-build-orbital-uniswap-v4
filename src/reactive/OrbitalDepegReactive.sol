// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IReactive, ISystemContract, IPayer} from "./IReactive.sol";

/// @title OrbitalDepegReactive
/// @notice Reactive Smart Contract (deployed on Reactive Lasna, chain id 5318007) that watches a
/// Chainlink aggregator's `AnswerUpdated` events for one of the pool's stablecoins and, when the
/// reported price leaves the peg band, emits a `Callback` to the destination chain (Unichain
/// Sepolia, 1301) targeting `OrbitalDepegCallback.depeg(...)`.
///
/// Deployment model (per Reactive docs): the same bytecode is instantiated once on the Reactive
/// Network (where it subscribes) and once inside the deployer's ReactVM (where `react` runs). The
/// two copies tell each other apart by whether the system contract has code at its address.
contract OrbitalDepegReactive is IReactive, IPayer {
    /// @dev Reactive system contract; present on the Reactive Network, absent in the ReactVM.
    address public constant SERVICE = 0x0000000000000000000000000000000000fffFfF;
    /// @dev Wildcard for topics a subscription does not filter on.
    uint256 public constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    /// @dev keccak256("AnswerUpdated(int256,uint256,uint256)") — Chainlink aggregator event.
    uint256 public constant ANSWER_UPDATED_TOPIC = uint256(keccak256("AnswerUpdated(int256,uint256,uint256)"));

    address public immutable owner;
    bool public immutable isReactVm;

    uint256 public immutable originChainId;
    address public immutable feed;
    uint256 public immutable destinationChainId;
    address public immutable callbackContract;
    uint64 public immutable callbackGasLimit;
    int256 public immutable pegPrice; // in feed decimals, e.g. 1e8 for a USD feed
    uint256 public immutable bandBps; // allowed deviation, basis points

    event DepegDetected(address indexed feed, int256 price, uint256 roundId);
    event PriceInBand(address indexed feed, int256 price, uint256 roundId);

    error NotOwner();
    error NotSystemContract();
    error UnexpectedLog();
    error InvalidConfig();
    error ReactiveNetworkOnly();
    error PaymentFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        uint256 _originChainId,
        address _feed,
        uint256 _destinationChainId,
        address _callbackContract,
        uint64 _callbackGasLimit,
        int256 _pegPrice,
        uint256 _bandBps
    ) payable {
        if (_feed == address(0) || _callbackContract == address(0) || _pegPrice <= 0 || _bandBps >= 10_000) {
            revert InvalidConfig();
        }
        owner = msg.sender;
        originChainId = _originChainId;
        feed = _feed;
        destinationChainId = _destinationChainId;
        callbackContract = _callbackContract;
        callbackGasLimit = _callbackGasLimit;
        pegPrice = _pegPrice;
        bandBps = _bandBps;

        isReactVm = SERVICE.code.length == 0;
        if (!isReactVm) {
            ISystemContract(SERVICE)
                .subscribe(
                    _originChainId, _feed, ANSWER_UPDATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
                );
        }
    }

    /// @notice True when `price` is outside [peg·(1 − band), peg·(1 + band)] or not positive.
    function isOutOfBand(int256 price) public view returns (bool) {
        if (price <= 0) return true;
        int256 tolerance = pegPrice * int256(bandBps) / 10_000;
        return price < pegPrice - tolerance || price > pegPrice + tolerance;
    }

    /// @inheritdoc IReactive
    /// @dev Called by the ReactVM for every log matching the subscription. The price is
    /// `AnswerUpdated`'s first indexed argument (`current`), the round id the second.
    function react(LogRecord calldata log) external override {
        if (msg.sender != SERVICE) revert NotSystemContract();
        if (log.chain_id != originChainId || log._contract != feed || log.topic_0 != ANSWER_UPDATED_TOPIC) {
            revert UnexpectedLog();
        }
        int256 price = int256(log.topic_1);
        uint256 roundId = log.topic_2;
        if (!isOutOfBand(price)) {
            emit PriceInBand(feed, price, roundId);
            return;
        }
        emit DepegDetected(feed, price, roundId);
        // First argument is a placeholder: the callback proxy replaces it with the RVM id.
        bytes memory payload =
            abi.encodeWithSignature("depeg(address,address,int256,uint256)", address(0), feed, price, roundId);
        emit Callback(destinationChainId, callbackContract, callbackGasLimit, payload);
    }

    // ---- operations -------------------------------------------------------------------------

    /// @notice Re-create the subscription (Reactive Network copy only).
    function subscribe() external onlyOwner {
        if (isReactVm) revert ReactiveNetworkOnly();
        ISystemContract(SERVICE)
            .subscribe(originChainId, feed, ANSWER_UPDATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice Stop watching the feed (Reactive Network copy only).
    function unsubscribe() external onlyOwner {
        if (isReactVm) revert ReactiveNetworkOnly();
        ISystemContract(SERVICE)
            .unsubscribe(originChainId, feed, ANSWER_UPDATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @inheritdoc IPayer
    /// @dev The system contract collects reactive-execution debt in REACT through this hook.
    function pay(uint256 amount) external override {
        if (msg.sender != SERVICE) revert NotSystemContract();
        (bool ok,) = SERVICE.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }

    function withdraw(address payable to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }

    receive() external payable {}
}
