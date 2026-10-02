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
        // The deployer owns the callback first (so a script can bind the hook), then hands over.
        callback = new OrbitalDepegCallback(address(proxy), address(hook), rvmId);
        callback.transferOwnership(owner);
        vm.prank(owner);
        hook.setGuardian(address(callback));
        reactive =
            new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 500_000, PEG, BAND_BPS, 0);
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
        return reactAs(r, feed, price, roundId);
    }

    /// @dev Feeds one `AnswerUpdated` log from `emitter` to the ReactVM copy and returns the last
    /// `Callback` payload it emitted, if any.
    function reactAs(OrbitalDepegReactive r, address emitter, int256 price, uint256 roundId)
        internal
        returns (bytes memory payload, bool emitted)
    {
        IReactive.LogRecord memory rec = logRecord(price, roundId);
        rec._contract = emitter;
        vm.recordLogs();
        vm.prank(SERVICE);
        r.react(rec);
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
            new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 500_000, PEG, BAND_BPS, 0);
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
            new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 500_000, PEG, BAND_BPS, 0);
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
            new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 1, PEG, bandBps, 0);
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
            new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 1, PEG, bandBps, 0);
        assertTrue(r.isOutOfBand(price));
        // Delivered as a topic, a negative answer is a huge uint; the contract must still trip.
        (, bool emitted) = reactAndCapture(r, price, 9);
        assertTrue(emitted, "callback requested for a non-positive answer");
    }

    function test_zeroBandTripsOnAnyDeviation() public {
        OrbitalDepegReactive r =
            new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 1, PEG, 0, 0);
        assertFalse(r.isOutOfBand(PEG));
        assertTrue(r.isOutOfBand(PEG + 1));
        assertTrue(r.isOutOfBand(PEG - 1));
    }

    function test_widestBandStillTripsOnCollapse() public {
        OrbitalDepegReactive r =
            new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 1, PEG, 9_999, 0);
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
        new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(0), 1, PEG, BAND_BPS, 0);
        vm.expectRevert(OrbitalDepegReactive.InvalidConfig.selector);
        new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 1, -1, BAND_BPS, 0);
        vm.expectRevert(OrbitalDepegReactive.InvalidConfig.selector);
        new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 1, PEG, 10_001, 0);
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
        // The callback sees the hook is already paused, records the round and acknowledges without
        // touching the hook (no `Paused` event, no revert): the delivery is still paid for and must
        // not fail, or the proxy would retry it.
        vm.recordLogs();
        (bool ok,) = proxy.deliver(address(callback), payload, rvmId);
        assertTrue(ok, "idempotent pause does not fail the delivery");
        assertTrue(hook.paused());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one acknowledgement, nothing from the hook");
        assertEq(logs[0].emitter, address(callback));
        assertEq(logs[0].topics[0], keccak256("DepegAlreadyPaused(address,int256,uint256)"));
        assertEq(callback.lastRoundId(feed), 1, "the round still counts as acted on");
        // After the owner resumes, the same round cannot re-pause (stale), a newer one can.
        vm.prank(owner);
        hook.unpause();
        (ok,) = proxy.deliver(address(callback), payload, rvmId);
        assertTrue(ok);
        assertFalse(hook.paused(), "a round already acted on never re-pauses");
        (payload,) = reactAndCapture(reactive, 1e8, 2); // in band: re-arm
        (payload,) = reactAndCapture(reactive, 0.5e8, 3);
        (ok,) = proxy.deliver(address(callback), payload, rvmId);
        assertTrue(ok);
        assertTrue(hook.paused(), "a newer out-of-band round pauses again");
    }

    /// With `retryEveryRounds = 0` the reactive side latches on the first out-of-band round and
    /// requests exactly one callback per excursion. If that one delivery fails on the destination
    /// (here: the callback is not yet bound to a hook; a wrong RVM id, an unset guardian or an
    /// unfunded callback behave the same), nothing retries it: every later round of the same
    /// excursion is only `DepegPersists`, and the pool stays open until a human pauses it or the
    /// price returns in band and leaves again. This was reported as a liveness gap of the
    /// keeper-free design; the revision answered it with the `retryEveryRounds` setting (tests
    /// below), and this is the documented behaviour of leaving that setting at zero.
    function test_failedDeliveryIsNotRetriedWithinTheExcursion() public {
        OrbitalDepegCallback unbound = new OrbitalDepegCallback(address(proxy), address(0), rvmId);
        OrbitalDepegReactive r =
            new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(unbound), 500_000, PEG, BAND_BPS, 0);
        vm.prank(owner);
        hook.setGuardian(address(unbound));

        (bytes memory payload, bool emitted) = reactAndCapture(r, 0.5e8, 1);
        assertTrue(emitted, "one callback for the excursion");
        (bool ok, bytes memory ret) = proxy.deliver(address(unbound), payload, rvmId);
        assertFalse(ok, "delivery fails on the destination");
        assertEq(bytes4(ret), OrbitalDepegCallback.HookNotSet.selector);
        assertFalse(hook.paused());

        // The operator fixes the destination, but the excursion is already latched: ten more
        // out-of-band rounds request nothing.
        unbound.setHook(address(hook));
        for (uint256 round = 2; round <= 11; round++) {
            (, emitted) = reactAndCapture(r, 0.5e8, round);
            assertFalse(emitted, "no retry while the excursion lasts");
        }
        assertFalse(hook.paused(), "the pool trades through the depeg");
        // Only a return in band re-arms the breaker; the next excursion is then caught.
        (, emitted) = reactAndCapture(r, 1e8, 12);
        assertFalse(emitted);
        (payload, emitted) = reactAndCapture(r, 0.5e8, 13);
        assertTrue(emitted);
        (ok,) = proxy.deliver(address(unbound), payload, rvmId);
        assertTrue(ok);
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
        OrbitalDepegCallback fresh = new OrbitalDepegCallback(address(other), address(hook), rvmId);
        fresh.transferOwnership(owner);
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

    function test_anotherAggregatorIsLatchedAndRoundTrackedOnItsOwn() public {
        // The ReactVM copy does not filter on the emitter (the Reactive Network copy's subscription
        // does, so a rotated aggregator can be followed without redeploying). What it must do is
        // keep every aggregator's latch and round counter apart: a log from a second feed trips
        // independently of the first feed's state, and its low round numbers are not "stale"
        // because the first feed is already at a high round.
        (bytes memory first,) = reactAndCapture(reactive, 0.5e8, 1_000);
        (bool ok,) = proxy.deliver(address(callback), first, rvmId);
        assertTrue(ok);
        assertTrue(hook.paused());
        assertTrue(reactive.tripped(feed), "first feed latched");
        vm.prank(owner);
        hook.unpause();

        address other = makeAddr("eth-usd-aggregator");
        IReactive.LogRecord memory rec = logRecord(0.1e8, 1);
        rec._contract = other;
        vm.recordLogs();
        vm.prank(SERVICE);
        reactive.react(rec);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory payload;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Callback(uint256,address,uint64,bytes)")) {
                payload = abi.decode(logs[i].data, (bytes));
            }
        }
        assertGt(payload.length, 0, "second feed trips although the first is still latched");
        assertTrue(reactive.tripped(other));
        assertTrue(reactive.tripped(feed), "first feed's latch untouched");
        (ok,) = proxy.deliver(address(callback), payload, rvmId);
        assertTrue(ok);
        assertTrue(hook.paused(), "round 1 of the other feed is not stale against round 1000 of the first");
        assertEq(callback.lastRoundId(other), 1);
        assertEq(callback.lastRoundId(feed), 1_000);
        // Logs that are not AnswerUpdated on the origin chain are still refused whoever emits them.
        rec.topic_0 = uint256(keccak256("Transfer(address,address,uint256)"));
        vm.prank(SERVICE);
        vm.expectRevert(OrbitalDepegReactive.UnexpectedLog.selector);
        reactive.react(rec);
    }

    // ---- retries: the revision's answer to the lost-delivery gap -----------------------------

    function withRetries(uint32 every) internal returns (OrbitalDepegReactive r) {
        r = new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 500_000, PEG, BAND_BPS, every);
        assertEq(r.retryEveryRounds(), every);
    }

    /// `retryEveryRounds = 1` is the most expensive setting: every out-of-band round of a tripped
    /// excursion requests (and pays for) a callback, each acknowledged on the destination.
    function test_retryEveryRoundRequestsACallbackOnEveryOutOfBandRound() public {
        OrbitalDepegReactive r = withRetries(1);
        (bytes memory payload, bool emitted) = reactAndCapture(r, 0.5e8, 1);
        assertTrue(emitted);
        (bool ok,) = proxy.deliver(address(callback), payload, rvmId);
        assertTrue(ok);
        assertTrue(hook.paused());
        for (uint256 round = 2; round <= 5; round++) {
            vm.expectEmit(true, false, false, true, address(r));
            emit OrbitalDepegReactive.DepegRetried(feed, 0.5e8, round);
            (payload, emitted) = reactAndCapture(r, 0.5e8, round);
            assertTrue(emitted, "one callback per round");
            assertEq(r.roundsSinceCallback(feed), 0, "counter resets on every retry");
            vm.expectEmit(true, false, false, true, address(callback));
            emit OrbitalDepegCallback.DepegAlreadyPaused(feed, 0.5e8, round);
            (ok,) = proxy.deliver(address(callback), payload, rvmId);
            assertTrue(ok, "a retry that finds the hook paused is acknowledged, not failed");
        }
        assertEq(callback.lastRoundId(feed), 5);
    }

    /// With retries on, an owner's `unpause()` during a sustained depeg is undone by the next retry
    /// (the README says so: the breaker only ever pauses, and a retry pauses again). The documented
    /// way to keep the pool open on purpose is to silence the breaker first; both documented
    /// switches make the retry's delivery fail without touching the hook, and restoring either one
    /// lets the following retry land.
    function test_retryRePausesAfterOwnerResumeUnlessTheBreakerIsSilenced() public {
        OrbitalDepegReactive r = withRetries(2);
        (bytes memory payload,) = reactAndCapture(r, 0.5e8, 1);
        (bool ok,) = proxy.deliver(address(callback), payload, rvmId);
        assertTrue(ok);
        assertTrue(hook.paused());

        vm.prank(owner);
        hook.unpause();
        (, bool emitted) = reactAndCapture(r, 0.5e8, 2);
        assertFalse(emitted, "round 2 only persists");
        assertFalse(hook.paused(), "the resume holds until the next retry");
        (payload, emitted) = reactAndCapture(r, 0.5e8, 3);
        assertTrue(emitted, "round 3 retries");
        (ok,) = proxy.deliver(address(callback), payload, rvmId);
        assertTrue(ok);
        assertTrue(hook.paused(), "the retry pauses the pool again after an owner resume");

        // Silence 1: no guardian. The retry's delivery reverts inside the hook; nothing is recorded,
        // so the round is not burnt as "acted on".
        vm.startPrank(owner);
        hook.unpause();
        hook.setGuardian(address(0));
        vm.stopPrank();
        (, emitted) = reactAndCapture(r, 0.5e8, 4);
        assertFalse(emitted);
        (payload, emitted) = reactAndCapture(r, 0.5e8, 5);
        assertTrue(emitted);
        bytes memory ret;
        (ok, ret) = proxy.deliver(address(callback), payload, rvmId);
        assertFalse(ok, "silenced: the delivery fails");
        assertEq(bytes4(ret), OrbitalHook.NotGuardian.selector);
        assertFalse(hook.paused(), "the pool stays open");
        assertEq(callback.lastRoundId(feed), 3, "a failed delivery records nothing");

        // Silence 2: RVM id cleared on the callback contract, guardian restored.
        vm.prank(owner);
        hook.setGuardian(address(callback));
        vm.prank(owner);
        callback.setRvmId(address(0));
        (, emitted) = reactAndCapture(r, 0.5e8, 6);
        (payload, emitted) = reactAndCapture(r, 0.5e8, 7);
        assertTrue(emitted);
        (ok, ret) = proxy.deliver(address(callback), payload, rvmId);
        assertFalse(ok);
        assertEq(bytes4(ret), OrbitalDepegCallback.WrongRvmId.selector);
        assertFalse(hook.paused());

        // Restored: the next retry of the same excursion pauses again.
        vm.prank(owner);
        callback.setRvmId(rvmId);
        (, emitted) = reactAndCapture(r, 0.5e8, 8);
        (payload, emitted) = reactAndCapture(r, 0.5e8, 9);
        assertTrue(emitted);
        (ok,) = proxy.deliver(address(callback), payload, rvmId);
        assertTrue(ok);
        assertTrue(hook.paused());
        assertEq(callback.lastRoundId(feed), 9);
    }

    /// Latches and retry counters are kept per emitting aggregator: one feed's retry or re-arm
    /// never moves another feed's count.
    function test_retryCountersArePerAggregator() public {
        OrbitalDepegReactive r = withRetries(2);
        address other = makeAddr("second-aggregator");
        (, bool emitted) = reactAs(r, feed, 0.5e8, 1);
        assertTrue(emitted);
        (, emitted) = reactAs(r, feed, 0.5e8, 2);
        assertFalse(emitted);
        (, emitted) = reactAs(r, other, 0.5e8, 1);
        assertTrue(emitted, "second feed trips on its own");
        assertEq(r.roundsSinceCallback(feed), 1);
        assertEq(r.roundsSinceCallback(other), 0);

        (, emitted) = reactAs(r, feed, 0.5e8, 3);
        assertTrue(emitted, "first feed retries");
        assertEq(r.roundsSinceCallback(feed), 0);
        assertEq(r.roundsSinceCallback(other), 0, "untouched by the first feed's retry");
        (, emitted) = reactAs(r, other, 0.5e8, 2);
        assertFalse(emitted, "second feed is one round into its interval");
        assertEq(r.roundsSinceCallback(other), 1);

        // Re-arming the first feed leaves the second feed's excursion where it was.
        (, emitted) = reactAs(r, feed, 1e8, 4);
        assertFalse(emitted);
        assertFalse(r.tripped(feed));
        assertTrue(r.tripped(other));
        assertEq(r.roundsSinceCallback(other), 1);
        (, emitted) = reactAs(r, other, 0.5e8, 3);
        assertTrue(emitted, "second feed retries on schedule");
    }

    /// Cadence as a property: after the trip, `extra` further out-of-band rounds request exactly
    /// `extra / every` callbacks (none when retries are off), the counter holds the remainder, and
    /// an in-band round clears it so the next excursion starts a fresh interval.
    /// forge-config: default.fuzz.runs = 300
    function testFuzz_retryCadence(uint32 every, uint8 extra) public {
        every = uint32(bound(every, 0, 24));
        extra = uint8(bound(extra, 0, 60));
        OrbitalDepegReactive r = withRetries(every);
        (, bool emitted) = reactAndCapture(r, 0.5e8, 1);
        assertTrue(emitted, "the first out-of-band round always trips");
        uint256 retries;
        for (uint256 k = 1; k <= extra; k++) {
            (, emitted) = reactAndCapture(r, 0.5e8, 1 + k);
            if (emitted) retries++;
        }
        assertEq(retries, every == 0 ? 0 : extra / every, "retries requested");
        assertEq(r.roundsSinceCallback(feed), every == 0 ? 0 : extra % every, "counter holds the remainder");
        assertTrue(r.tripped(feed));

        (, emitted) = reactAndCapture(r, 1e8, 100);
        assertFalse(emitted);
        assertFalse(r.tripped(feed));
        assertEq(r.roundsSinceCallback(feed), 0, "re-arm clears the counter");
        (, emitted) = reactAndCapture(r, 0.5e8, 101);
        assertTrue(emitted, "next excursion trips at once");
        assertEq(r.roundsSinceCallback(feed), 0);
        if (every > 1) {
            (, emitted) = reactAndCapture(r, 0.5e8, 102);
            assertFalse(emitted, "fresh interval");
        }
    }
}
