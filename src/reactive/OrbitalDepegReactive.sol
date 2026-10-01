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
/// Network (where it subscribes and the owner manages subscriptions) and once inside the deployer's
/// ReactVM (where `react` runs, in transactions sent from the RVM id — the deployer EOA). The two
/// copies tell each other apart by whether the system contract has code at its address. The ReactVM
/// copy's storage can only change through `react`, so the subscription on the Reactive Network copy
/// is what decides which aggregator's logs reach it; `react` validates the chain and the event
/// signature and takes the emitter from the log.
///
/// The breaker is latched per emitter: the first out-of-band round of an excursion requests one
/// callback; further out-of-band rounds only log `DepegPersists` until an in-band round re-arms it.
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
    uint256 public immutable destinationChainId;
    address public immutable callbackContract;
    uint64 public immutable callbackGasLimit;
    int256 public immutable pegPrice; // in feed decimals, e.g. 1e8 for a USD feed
    uint256 public immutable bandBps; // allowed deviation, basis points

    /// @notice Aggregator currently subscribed to (Reactive Network copy; the ReactVM copy keeps
    /// the value it was deployed with and does not filter on it).
    address public feed;
    /// @notice Latch per emitter: true after a callback was requested for an excursion that has
    /// not yet seen an in-band round.
    mapping(address => bool) public tripped;

    event DepegDetected(address indexed feed, int256 price, uint256 roundId);
    event DepegPersists(address indexed feed, int256 price, uint256 roundId);
    event PriceInBand(address indexed feed, int256 price, uint256 roundId);
    event FeedUpdated(address indexed previousFeed, address indexed newFeed);

    error NotOwner();
    error NotSystemContract();
    error UnexpectedLog();
    error InvalidConfig();
    error ReactiveNetworkOnly();
    error ReactiveVmOnly();
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
        if (!isReactVm) _subscribe(_feed);
    }

    /// @notice True when `price` is outside [peg·(1 − band), peg·(1 + band)] or not positive.
    function isOutOfBand(int256 price) public view returns (bool) {
        if (price <= 0) return true;
        int256 tolerance = pegPrice * int256(bandBps) / 10_000;
        return price < pegPrice - tolerance || price > pegPrice + tolerance;
    }

    /// @inheritdoc IReactive
    /// @dev Runs only inside the ReactVM, where the Reactive Network delivers every log matching the
    /// subscription as a transaction from the RVM id. There is no system-contract sender to check
    /// (it has no code there), which is also how `reactive-lib`'s `AbstractReactive` guards `react`.
    /// The price is `AnswerUpdated`'s first indexed argument (`current`), the round id the second.
    function react(LogRecord calldata log) external override {
        if (!isReactVm) revert ReactiveVmOnly();
        if (log.chain_id != originChainId || log.topic_0 != ANSWER_UPDATED_TOPIC) revert UnexpectedLog();
        address emitter = log._contract;
        int256 price = int256(log.topic_1);
        uint256 roundId = log.topic_2;
        if (!isOutOfBand(price)) {
            if (tripped[emitter]) tripped[emitter] = false; // re-arm
            emit PriceInBand(emitter, price, roundId);
            return;
        }
        if (tripped[emitter]) {
            emit DepegPersists(emitter, price, roundId);
            return;
        }
        tripped[emitter] = true;
        emit DepegDetected(emitter, price, roundId);
        // First argument is a placeholder: the callback proxy replaces it with the RVM id.
        bytes memory payload =
            abi.encodeWithSignature("depeg(address,address,int256,uint256)", address(0), emitter, price, roundId);
        emit Callback(destinationChainId, callbackContract, callbackGasLimit, payload);
    }

    // ---- operations (Reactive Network copy only) -------------------------------------------

    /// @notice Re-create the subscription to the current feed.
    function subscribe() external onlyOwner {
        if (isReactVm) revert ReactiveNetworkOnly();
        _subscribe(feed);
    }

    /// @notice Stop watching the current feed.
    function unsubscribe() external onlyOwner {
        if (isReactVm) revert ReactiveNetworkOnly();
        _unsubscribe(feed);
    }

    /// @notice Follow a Chainlink aggregator rotation: drop the old subscription (best effort, so
    /// an already-removed subscription cannot block the switch) and subscribe to `newFeed`.
    function setFeed(address newFeed) external onlyOwner {
        if (isReactVm) revert ReactiveNetworkOnly();
        if (newFeed == address(0)) revert InvalidConfig();
        address old = feed;
        feed = newFeed;
        try ISystemContract(SERVICE)
            .unsubscribe(originChainId, old, ANSWER_UPDATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE) {}
            catch {}
        _subscribe(newFeed);
        emit FeedUpdated(old, newFeed);
    }

    function _subscribe(address _feed) internal {
        ISystemContract(SERVICE)
            .subscribe(originChainId, _feed, ANSWER_UPDATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _unsubscribe(address _feed) internal {
        ISystemContract(SERVICE)
            .unsubscribe(originChainId, _feed, ANSWER_UPDATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
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
