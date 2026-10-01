// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {OrbitalFixture} from "./utils/OrbitalFixture.sol";
import {OrbitalHook} from "../src/OrbitalHook.sol";
import {IReactive, ISystemContract} from "../src/reactive/IReactive.sol";
import {OrbitalDepegReactive} from "../src/reactive/OrbitalDepegReactive.sol";
import {OrbitalDepegCallback} from "../src/reactive/OrbitalDepegCallback.sol";

/// @dev Stand-in for the Reactive Network system contract, etched at its fixed address so the
/// reactive contract believes it is the Reactive Network copy (not the ReactVM copy).
contract MockSystemContract is ISystemContract {
    struct Sub {
        uint256 chainId;
        address target;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    uint256 public subscribes;
    uint256 public unsubscribes;
    Sub public last;
    address public lastCaller;

    function subscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external {
        subscribes++;
        last = Sub(chain_id, _contract, topic_0, topic_1, topic_2, topic_3);
        lastCaller = msg.sender;
    }

    function unsubscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external {
        unsubscribes++;
        last = Sub(chain_id, _contract, topic_0, topic_1, topic_2, topic_3);
        lastCaller = msg.sender;
    }

    receive() external payable {}
}

contract RejectsEther {
    receive() external payable {
        revert("no");
    }
}

/// @dev Same role as the proxy mock in `Reactive.t.sol`, declared here so this file is standalone.
contract ProxyStandIn {
    function deliver(address target, bytes memory payload, address rvmId) external returns (bool ok, bytes memory ret) {
        assembly ("memory-safe") {
            mstore(add(payload, 36), rvmId)
        }
        (ok, ret) = target.call(payload);
    }

    function charge(address target, uint256 amount) external {
        OrbitalDepegCallback(payable(target)).pay(amount);
    }

    receive() external payable {}
}

/// @notice Failure paths of the depeg breaker beyond the happy delivery: the Reactive Network copy
/// (subscription management), band arithmetic as properties, payment failures, admin rotation and
/// what the breaker can never do (resume the pool).
contract ReactiveEdgeTest is OrbitalFixture {
    uint256 constant ORIGIN_CHAIN = 11155111;
    uint256 constant DEST_CHAIN = 1301;
    address constant SERVICE = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    address feed = makeAddr("chainlink-aggregator");
    address rvmId = makeAddr("reactive-deployer");
    int256 constant PEG = 1e8;
    uint256 constant BAND_BPS = 200;

    ProxyStandIn proxy;
    OrbitalDepegCallback callback;
    OrbitalDepegReactive reactive;

    function setUp() public override {
        super.setUp();
        proxy = new ProxyStandIn();
        callback = new OrbitalDepegCallback(address(proxy), address(hook), rvmId, owner);
        vm.prank(owner);
        hook.setGuardian(address(callback));
        reactive = new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 500_000, PEG, BAND_BPS);
        vm.deal(address(callback), 1 ether);
        depositAs(lp, WIDE, 1_000_000e18);
    }

    function logRecord(int256 price, uint256 roundId) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN,
            _contract: feed,
            topic_0: uint256(keccak256("AnswerUpdated(int256,uint256,uint256)")),
            topic_1: uint256(price),
            topic_2: roundId,
            topic_3: 0,
            data: abi.encode(block.timestamp),
            block_number: 1,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function reactAndCapture(OrbitalDepegReactive r, int256 price, uint256 roundId)
        internal
        returns (bytes memory payload, bool emitted)
    {
        vm.recordLogs();
        vm.prank(SERVICE);
        r.react(logRecord(price, roundId));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                payload = abi.decode(logs[i].data, (bytes));
                emitted = true;
            }
        }
    }

    // ---- Reactive Network copy ---------------------------------------------------------------

    function etchSystemContract() internal returns (MockSystemContract sys) {
        MockSystemContract impl = new MockSystemContract();
        vm.etch(SERVICE, address(impl).code);
        sys = MockSystemContract(payable(SERVICE));
    }

    function test_networkCopySubscribesToTheFeedInItsConstructor() public {
        MockSystemContract sys = etchSystemContract();
        OrbitalDepegReactive net =
            new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 500_000, PEG, BAND_BPS);
        assertFalse(net.isReactVm(), "sees the system contract: network copy");
        assertEq(sys.subscribes(), 1, "subscribed once");
        assertEq(sys.lastCaller(), address(net));
        (uint256 chainId, address target, uint256 t0, uint256 t1, uint256 t2, uint256 t3) = sys.last();
        assertEq(chainId, ORIGIN_CHAIN);
        assertEq(target, feed, "subscribes to the aggregator, not the proxy");
        assertEq(t0, uint256(keccak256("AnswerUpdated(int256,uint256,uint256)")));
        assertEq(t1, REACTIVE_IGNORE);
        assertEq(t2, REACTIVE_IGNORE);
        assertEq(t3, REACTIVE_IGNORE);
        assertEq(net.owner(), address(this));
    }

    function test_networkCopySubscriptionManagementIsOwnerOnly() public {
        MockSystemContract sys = etchSystemContract();
        OrbitalDepegReactive net =
            new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 500_000, PEG, BAND_BPS);
        vm.prank(trader);
        vm.expectRevert(OrbitalDepegReactive.NotOwner.selector);
        net.unsubscribe();
        vm.prank(trader);
        vm.expectRevert(OrbitalDepegReactive.NotOwner.selector);
        net.subscribe();
        net.unsubscribe();
        assertEq(sys.unsubscribes(), 1);
        net.subscribe();
        assertEq(sys.subscribes(), 2);
        // The system contract collects debt from the network copy.
        vm.deal(address(net), 1 ether);
        vm.prank(SERVICE);
        net.pay(0.3 ether);
        assertEq(SERVICE.balance, 0.3 ether);
        assertEq(address(net).balance, 0.7 ether);
    }

    function test_reactVmCopyNeverTalksToTheSystemContract() public view {
        assertTrue(reactive.isReactVm());
        assertEq(SERVICE.code.length, 0, "no system contract in the VM");
    }

    // ---- band arithmetic as properties -------------------------------------------------------

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_pegIsAlwaysInBandAndBandIsSymmetric(uint256 bandBps, int256 delta) public {
        bandBps = bound(bandBps, 0, 9_999);
        delta = bound(delta, 0, PEG - 1);
        OrbitalDepegReactive r =
            new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 1, PEG, bandBps);
        assertFalse(r.isOutOfBand(PEG), "the peg itself is always in band");
        assertEq(r.isOutOfBand(PEG - delta), r.isOutOfBand(PEG + delta), "band is symmetric around the peg");
        // Monotone: anything further from the peg than an out-of-band price is out of band too.
        if (r.isOutOfBand(PEG - delta)) {
            assertTrue(r.isOutOfBand(PEG - delta - 1));
            assertTrue(r.isOutOfBand(PEG + delta + 1));
        }
        if (!r.isOutOfBand(PEG + delta) && delta > 0) {
            assertFalse(r.isOutOfBand(PEG + delta - 1));
            assertFalse(r.isOutOfBand(PEG - delta + 1));
        }
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_nonPositivePricesAlwaysTrip(int256 price, uint256 bandBps) public {
        bandBps = bound(bandBps, 0, 9_999);
        price = bound(price, type(int256).min, 0);
        OrbitalDepegReactive r =
            new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 1, PEG, bandBps);
        assertTrue(r.isOutOfBand(price));
        // Delivered as a topic, a negative answer is a huge uint; the contract must still trip.
        (, bool emitted) = reactAndCapture(r, price, 9);
        assertTrue(emitted, "callback requested for a non-positive answer");
    }

    function test_zeroBandTripsOnAnyDeviation() public {
        OrbitalDepegReactive r = new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 1, PEG, 0);
        assertFalse(r.isOutOfBand(PEG));
        assertTrue(r.isOutOfBand(PEG + 1));
        assertTrue(r.isOutOfBand(PEG - 1));
    }

    function test_widestBandStillTripsOnCollapse() public {
        OrbitalDepegReactive r =
            new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 1, PEG, 9_999);
        // 1e8·(1 − 0.9999) = 1e4 is the lowest in-band price; anything under it trips.
        assertFalse(r.isOutOfBand(10_000));
        assertTrue(r.isOutOfBand(9_999));
        assertTrue(r.isOutOfBand(1));
        assertTrue(r.isOutOfBand(0));
        assertFalse(r.isOutOfBand(PEG + PEG * 9_999 / 10_000));
        assertTrue(r.isOutOfBand(PEG + PEG * 9_999 / 10_000 + 1));
    }

    function test_constructorRejectsNonPositivePegAndZeroCallback() public {
        vm.expectRevert(OrbitalDepegReactive.InvalidConfig.selector);
        new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(0), 1, PEG, BAND_BPS);
        vm.expectRevert(OrbitalDepegReactive.InvalidConfig.selector);
        new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 1, -1, BAND_BPS);
        vm.expectRevert(OrbitalDepegReactive.InvalidConfig.selector);
        new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 1, PEG, 10_001);
    }

    // ---- payload shape -----------------------------------------------------------------------

    function test_callbackPayloadCarriesFeedPriceAndRound() public {
        (bytes memory payload, bool emitted) = reactAndCapture(reactive, 0.9e8, 77);
        assertTrue(emitted);
        assertEq(payload.length, 4 + 4 * 32, "selector + four words");
        bytes memory args = new bytes(payload.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = payload[i + 4];
        }
        (address placeholder, address f, int256 price, uint256 round) =
            abi.decode(args, (address, address, int256, uint256));
        assertEq(placeholder, address(0), "RVM id slot left for the proxy to fill");
        assertEq(f, feed);
        assertEq(price, 0.9e8);
        assertEq(round, 77);
    }

    function test_inBandEmitsPriceInBandAndNoCallback() public {
        vm.expectEmit(true, false, false, true, address(reactive));
        emit OrbitalDepegReactive.PriceInBand(feed, 1.005e8, 5);
        (, bool emitted) = reactAndCapture(reactive, 1.005e8, 5);
        assertFalse(emitted);
    }

    function test_depegEmitsDepegDetectedBeforeCallback() public {
        vm.expectEmit(true, false, false, true, address(reactive));
        emit OrbitalDepegReactive.DepegDetected(feed, 0.5e8, 6);
        (, bool emitted) = reactAndCapture(reactive, 0.5e8, 6);
        assertTrue(emitted);
    }

    // ---- what the breaker cannot do ----------------------------------------------------------

    function test_breakerCanOnlyPauseNeverResume() public {
        (bytes memory payload,) = reactAndCapture(reactive, 0.5e8, 1);
        (bool ok,) = proxy.deliver(address(callback), payload, rvmId);
        assertTrue(ok);
        assertTrue(hook.paused());
        // An in-band update later produces no callback, and even a delivered one cannot unpause.
        (, bool emitted) = reactAndCapture(reactive, 1e8, 2);
        assertFalse(emitted);
        assertTrue(hook.paused(), "the breaker never resumes the pool");
        // The callback contract has no path to `unpause`: it is not the owner.
        vm.prank(address(callback));
        vm.expectRevert(OrbitalHook.NotOwner.selector);
        hook.unpause();
        // Withdrawals keep working for LPs while the breaker holds the pool.
        vm.prank(lp);
        uint256[] memory got = hook.withdraw(WIDE, 1_000_000e18, zeros());
        assertGt(got[0], 0);
    }

    function test_deliveryWhilePausedIsHarmlessAndStillEmits() public {
        vm.prank(owner);
        hook.pause();
        (bytes memory payload,) = reactAndCapture(reactive, 0.5e8, 1);
        vm.expectEmit(true, false, false, true, address(callback));
        emit OrbitalDepegCallback.DepegPauseTriggered(feed, 0.5e8, 1);
        (bool ok,) = proxy.deliver(address(callback), payload, rvmId);
        assertTrue(ok, "idempotent pause does not fail the delivery");
        assertTrue(hook.paused());
    }

    function test_ownerOfTheCallbackCannotTriggerItDirectly() public {
        vm.prank(owner);
        vm.expectRevert(OrbitalDepegCallback.NotCallbackProxy.selector);
        callback.depeg(rvmId, feed, 0.5e8, 1);
        assertFalse(hook.paused());
    }

    function test_rvmIdRotationRejectsTheOldId() public {
        address newId = makeAddr("new-deployer");
        vm.prank(owner);
        callback.setRvmId(newId);
        (bytes memory payload,) = reactAndCapture(reactive, 0.5e8, 1);
        (bool ok, bytes memory ret) = proxy.deliver(address(callback), payload, rvmId);
        assertFalse(ok);
        assertEq(bytes4(ret), OrbitalDepegCallback.WrongRvmId.selector);
        assertFalse(hook.paused());
        (ok,) = proxy.deliver(address(callback), payload, newId);
        assertTrue(ok);
        assertTrue(hook.paused());
    }

    function test_proxyRotationIsImmutable() public {
        // There is no setter for the proxy: a wrong proxy at deployment means a dead breaker, and
        // the only remedy is redeploying the callback and re-pointing the hook's guardian.
        ProxyStandIn other = new ProxyStandIn();
        (bytes memory payload,) = reactAndCapture(reactive, 0.5e8, 1);
        (bool ok, bytes memory ret) = other.deliver(address(callback), payload, rvmId);
        assertFalse(ok);
        assertEq(bytes4(ret), OrbitalDepegCallback.NotCallbackProxy.selector);
        OrbitalDepegCallback fresh = new OrbitalDepegCallback(address(other), address(hook), rvmId, owner);
        vm.prank(owner);
        hook.setGuardian(address(fresh));
        (ok,) = other.deliver(address(fresh), payload, rvmId);
        assertTrue(ok);
        assertTrue(hook.paused());
    }

    // ---- funding and payment failures --------------------------------------------------------

    function test_callbackPaymentFailsWhenUnderfunded() public {
        vm.expectRevert(OrbitalDepegCallback.PaymentFailed.selector);
        proxy.charge(address(callback), 2 ether);
        proxy.charge(address(callback), 1 ether);
        assertEq(address(callback).balance, 0);
        assertEq(address(proxy).balance, 1 ether);
    }

    function test_callbackWithdrawFailures() public {
        RejectsEther sink = new RejectsEther();
        vm.prank(owner);
        vm.expectRevert(OrbitalDepegCallback.PaymentFailed.selector);
        callback.withdraw(payable(address(sink)), 0.1 ether);
        vm.prank(owner);
        vm.expectRevert(OrbitalDepegCallback.PaymentFailed.selector);
        callback.withdraw(payable(owner), 2 ether);
        // Zero-address ownership is refused; after a transfer the old owner is locked out.
        vm.prank(owner);
        vm.expectRevert(OrbitalDepegCallback.ZeroAddress.selector);
        callback.transferOwnership(address(0));
        vm.prank(owner);
        callback.transferOwnership(trader);
        vm.prank(owner);
        vm.expectRevert(OrbitalDepegCallback.NotOwner.selector);
        callback.withdraw(payable(owner), 1);
        vm.prank(trader);
        callback.withdraw(payable(trader), 1 ether);
        assertEq(trader.balance, 1 ether);
    }

    function test_callbackAcceptsPlainEther() public {
        (bool ok,) = address(callback).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(address(callback).balance, 1.5 ether);
    }

    function test_reactivePaymentFailsWhenUnderfunded() public {
        vm.prank(SERVICE);
        vm.expectRevert(OrbitalDepegReactive.PaymentFailed.selector);
        reactive.pay(1);
        RejectsEther sink = new RejectsEther();
        vm.deal(address(reactive), 1 ether);
        vm.expectRevert(OrbitalDepegReactive.PaymentFailed.selector);
        reactive.withdraw(payable(address(sink)), 1);
        (bool ok,) = address(reactive).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(reactive).balance, 2 ether);
    }

    function test_reactRejectsTheSameLogShapeFromAnotherAggregator() public {
        // A log from a different feed on the right chain with the right topic is still refused:
        // the breaker watches exactly one aggregator.
        IReactive.LogRecord memory rec = logRecord(0.1e8, 1);
        rec._contract = makeAddr("eth-usd-aggregator");
        vm.prank(SERVICE);
        vm.expectRevert(OrbitalDepegReactive.UnexpectedLog.selector);
        reactive.react(rec);
        assertFalse(hook.paused());
    }
}
