// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {OrbitalFixture} from "./utils/OrbitalFixture.sol";
import {OrbitalHook} from "../src/OrbitalHook.sol";
import {IReactive} from "../src/reactive/IReactive.sol";
import {OrbitalDepegReactive} from "../src/reactive/OrbitalDepegReactive.sol";
import {OrbitalDepegCallback} from "../src/reactive/OrbitalDepegCallback.sol";

/// @dev Stands in for the Reactive callback proxy on the destination chain: it delivers a
/// `Callback` payload after overwriting the first argument with the RVM id, exactly as the real
/// proxy does, and charges the target through `pay`.
contract MockCallbackProxy {
    function deliver(address target, bytes memory payload, address rvmId) external returns (bool ok, bytes memory ret) {
        // The first ABI word after the selector is the placeholder address.
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

/// @dev Stands in for the Reactive Network system contract: records subscriptions. Etched at the
/// system address to model the Reactive Network copy of the reactive contract.
contract MockSystemContract {
    struct Sub {
        uint256 chainId;
        address emitter;
        uint256 topic0;
    }

    Sub[] public subs;
    Sub[] public unsubs;
    bool public failUnsubscribe;

    function subscribe(uint256 chainId, address emitter, uint256 topic0, uint256, uint256, uint256) external {
        subs.push(Sub(chainId, emitter, topic0));
    }

    function unsubscribe(uint256 chainId, address emitter, uint256 topic0, uint256, uint256, uint256) external {
        require(!failUnsubscribe, "no such subscription");
        unsubs.push(Sub(chainId, emitter, topic0));
    }

    function setFailUnsubscribe(bool f) external {
        failUnsubscribe = f;
    }

    function subCount() external view returns (uint256) {
        return subs.length;
    }

    function unsubCount() external view returns (uint256) {
        return unsubs.length;
    }
}

contract ReactiveBreakerTest is OrbitalFixture {
    uint256 constant ORIGIN_CHAIN = 11155111; // Ethereum Sepolia, where the feed lives
    uint256 constant DEST_CHAIN = 1301; // Unichain Sepolia
    address constant SERVICE = 0x0000000000000000000000000000000000fffFfF;
    address feed = makeAddr("chainlink-usdc-usd");
    address rvmId = makeAddr("reactive-deployer");
    int256 constant PEG = 1e8;
    uint256 constant BAND_BPS = 200; // 2%

    MockCallbackProxy proxy;
    OrbitalDepegCallback callback;
    OrbitalDepegReactive reactive;

    function setUp() public override {
        super.setUp();
        proxy = new MockCallbackProxy();
        callback = new OrbitalDepegCallback(address(proxy), address(hook), rvmId);
        callback.transferOwnership(owner);
        vm.prank(owner);
        hook.setGuardian(address(callback));
        // Deployed from the RVM id, as on Reactive Lasna. The system contract has no code in this
        // test, so the contract knows it is the ReactVM copy (no subscribe call), which is also
        // where `react` runs for real.
        vm.prank(rvmId);
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

    /// @dev Runs `react` the way the ReactVM does (a transaction from the RVM id) and returns the
    /// payload of the emitted `Callback`, or empty when none.
    function reactAndCapture(IReactive.LogRecord memory rec) internal returns (bytes memory payload, bool emitted) {
        vm.recordLogs();
        vm.prank(rvmId, rvmId);
        reactive.react(rec);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                assertEq(uint256(logs[i].topics[1]), DEST_CHAIN, "destination chain");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(callback), "callback target");
                assertEq(uint256(logs[i].topics[3]), 500_000, "gas limit");
                payload = abi.decode(logs[i].data, (bytes));
                emitted = true;
            }
        }
    }

    function reactAndCapture(int256 price, uint256 roundId) internal returns (bytes memory payload, bool emitted) {
        return reactAndCapture(logRecord(price, roundId));
    }

    // ---- end to end -------------------------------------------------------------------------

    function test_depegPausesThePoolEndToEnd() public {
        assertFalse(hook.paused());
        (bytes memory payload, bool emitted) = reactAndCapture(0.97e8, 42);
        assertTrue(emitted, "callback requested");
        assertEq(bytes4(payload), bytes4(keccak256("depeg(address,address,int256,uint256)")));
        (, address feedArg, int256 priceArg, uint256 roundArg) =
            abi.decode(slice(payload, 4), (address, address, int256, uint256));
        assertEq(feedArg, feed);
        assertEq(priceArg, 0.97e8);
        assertEq(roundArg, 42);

        vm.expectEmit(true, false, false, true, address(callback));
        emit OrbitalDepegCallback.DepegPauseTriggered(feed, 0.97e8, 42);
        (bool ok,) = proxy.deliver(address(callback), payload, rvmId);
        assertTrue(ok, "delivery succeeded");
        assertTrue(hook.paused(), "pool paused by the breaker");
        assertEq(callback.lastRoundId(feed), 42);

        vm.expectRevert();
        swapAs(trader, keyAB, true, -1e18);

        // A repeated delivery of the same round is acknowledged and ignored.
        vm.expectEmit(true, false, false, true, address(callback));
        emit OrbitalDepegCallback.StaleRoundIgnored(feed, 0.97e8, 42);
        (ok,) = proxy.deliver(address(callback), payload, rvmId);
        assertTrue(ok);

        // Only the owner can resume.
        vm.prank(owner);
        hook.unpause();
        assertFalse(hook.paused());
    }

    function test_latchRequestsOneCallbackPerExcursion() public {
        (, bool emitted) = reactAndCapture(0.9e8, 1);
        assertTrue(emitted, "first out-of-band round trips");
        assertTrue(reactive.tripped(feed));
        for (uint256 r = 2; r <= 5; r++) {
            vm.expectEmit(true, false, false, true, address(reactive));
            emit OrbitalDepegReactive.DepegPersists(feed, 0.9e8, r);
            (, emitted) = reactAndCapture(0.9e8, r);
            assertFalse(emitted, "no further callbacks while the excursion lasts");
        }
        // Back in band: re-armed. The next excursion trips again.
        (, emitted) = reactAndCapture(1.0e8, 6);
        assertFalse(emitted);
        assertFalse(reactive.tripped(feed));
        (, emitted) = reactAndCapture(1.05e8, 7);
        assertTrue(emitted, "a new excursion trips again");
    }

    function test_ownerResumeIsNotUndoneByTheSameExcursion() public {
        (bytes memory payload,) = reactAndCapture(0.9e8, 1);
        proxy.deliver(address(callback), payload, rvmId);
        assertTrue(hook.paused());
        vm.prank(owner);
        hook.unpause();
        // The feed keeps printing out of band: the latch holds, nothing is delivered, the pool
        // stays open until the owner decides otherwise.
        (, bool emitted) = reactAndCapture(0.9e8, 2);
        assertFalse(emitted);
        assertFalse(hook.paused());
    }

    function test_callbackSkipsWhenAlreadyPaused() public {
        vm.prank(owner);
        hook.pause();
        (bytes memory payload,) = reactAndCapture(0.9e8, 9);
        vm.expectEmit(true, false, false, true, address(callback));
        emit OrbitalDepegCallback.DepegAlreadyPaused(feed, 0.9e8, 9);
        (bool ok,) = proxy.deliver(address(callback), payload, rvmId);
        assertTrue(ok);
        assertEq(callback.lastRoundId(feed), 9, "round recorded even when nothing was done");
    }

    function test_callbackIgnoresOlderRounds() public {
        (bytes memory late,) = reactAndCapture(0.9e8, 20);
        (, bool emitted) = reactAndCapture(1.0e8, 21); // re-arm
        assertFalse(emitted);
        (bytes memory fresh,) = reactAndCapture(0.9e8, 22);
        proxy.deliver(address(callback), fresh, rvmId);
        assertTrue(hook.paused());
        vm.prank(owner);
        hook.unpause();
        // A delayed delivery for round 20 arrives after round 22 was acted on: ignored.
        (bool ok,) = proxy.deliver(address(callback), late, rvmId);
        assertTrue(ok);
        assertFalse(hook.paused(), "a stale round does not re-pause");
    }

    function test_priceAboveBandAlsoTrips() public {
        (bytes memory payload, bool emitted) = reactAndCapture(1.03e8, 7);
        assertTrue(emitted);
        (bool ok,) = proxy.deliver(address(callback), payload, rvmId);
        assertTrue(ok);
        assertTrue(hook.paused());
    }

    function test_nonPositivePriceTrips() public {
        (, bool emitted) = reactAndCapture(0, 1);
        assertTrue(emitted);
        (, emitted) = reactAndCapture(1e8, 2); // re-arm
        assertFalse(emitted);
        (, emitted) = reactAndCapture(-1, 3);
        assertTrue(emitted);
    }

    function test_inBandPriceDoesNothing() public {
        (, bool emitted) = reactAndCapture(1.01e8, 3);
        assertFalse(emitted, "no callback in band");
        (, emitted) = reactAndCapture(0.98e8, 4); // exactly at the edge is still in band
        assertFalse(emitted);
        assertFalse(hook.paused());
    }

    function test_bandMath() public view {
        assertFalse(reactive.isOutOfBand(1e8));
        assertFalse(reactive.isOutOfBand(0.98e8));
        assertFalse(reactive.isOutOfBand(1.02e8));
        assertTrue(reactive.isOutOfBand(0.98e8 - 1));
        assertTrue(reactive.isOutOfBand(1.02e8 + 1));
    }

    // ---- failure paths: reactive side -------------------------------------------------------

    function test_reactRunsOnlyInTheReactVm() public {
        // The ReactVM copy accepts the log from the RVM id (checked above). The Reactive Network
        // copy, which can tell the system contract has code, refuses to react at all.
        MockSystemContract sys = new MockSystemContract();
        vm.etch(SERVICE, address(sys).code);
        vm.prank(rvmId);
        OrbitalDepegReactive rn =
            new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 500_000, PEG, BAND_BPS);
        assertFalse(rn.isReactVm());
        assertEq(MockSystemContract(SERVICE).subCount(), 1, "subscribed in the constructor");
        vm.prank(rvmId, rvmId);
        vm.expectRevert(OrbitalDepegReactive.ReactiveVmOnly.selector);
        rn.react(logRecord(0.5e8, 1));
    }

    function test_reactiveNetworkCopyManagesSubscriptionsAndFeedRotation() public {
        MockSystemContract sys = new MockSystemContract();
        vm.etch(SERVICE, address(sys).code);
        vm.prank(rvmId);
        OrbitalDepegReactive rn =
            new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 500_000, PEG, BAND_BPS);
        MockSystemContract live = MockSystemContract(SERVICE);
        (uint256 chainId, address emitter, uint256 topic0) = live.subs(0);
        assertEq(chainId, ORIGIN_CHAIN);
        assertEq(emitter, feed);
        assertEq(topic0, rn.ANSWER_UPDATED_TOPIC());

        vm.prank(trader);
        vm.expectRevert(OrbitalDepegReactive.NotOwner.selector);
        rn.setFeed(makeAddr("x"));
        vm.prank(rvmId);
        vm.expectRevert(OrbitalDepegReactive.InvalidConfig.selector);
        rn.setFeed(address(0));

        // Chainlink rotates the aggregator: re-point in one transaction.
        address feed2 = makeAddr("chainlink-usdc-usd-v2");
        vm.prank(rvmId);
        vm.expectEmit(true, true, false, true, address(rn));
        emit OrbitalDepegReactive.FeedUpdated(feed, feed2);
        rn.setFeed(feed2);
        assertEq(rn.feed(), feed2);
        assertEq(live.unsubCount(), 1);
        (, emitter,) = live.unsubs(0);
        assertEq(emitter, feed, "old feed dropped");
        assertEq(live.subCount(), 2);
        (, emitter,) = live.subs(1);
        assertEq(emitter, feed2, "new feed watched");

        // A failing unsubscribe (already gone) never blocks the switch.
        live.setFailUnsubscribe(true);
        address feed3 = makeAddr("chainlink-usdc-usd-v3");
        vm.prank(rvmId);
        rn.setFeed(feed3);
        assertEq(rn.feed(), feed3);
        assertEq(live.subCount(), 3);

        vm.startPrank(rvmId);
        live.setFailUnsubscribe(false);
        rn.unsubscribe();
        assertEq(live.unsubCount(), 2);
        rn.subscribe();
        assertEq(live.subCount(), 4);
        vm.stopPrank();
    }

    function test_reactVmCopyFollowsTheRotatedAggregator() public {
        // The ReactVM copy cannot be re-pointed (its storage only changes through `react`), so it
        // takes the emitter from the log: once the Reactive Network copy subscribes to the new
        // aggregator, its rounds trip the breaker and are latched separately.
        address feed2 = makeAddr("chainlink-usdc-usd-v2");
        IReactive.LogRecord memory rec = logRecord(0.9e8, 1);
        rec._contract = feed2;
        (bytes memory payload, bool emitted) = reactAndCapture(rec);
        assertTrue(emitted);
        assertTrue(reactive.tripped(feed2));
        assertFalse(reactive.tripped(feed));
        (, address feedArg,,) = abi.decode(slice(payload, 4), (address, address, int256, uint256));
        assertEq(feedArg, feed2, "payload names the emitting aggregator");
        (bool ok,) = proxy.deliver(address(callback), payload, rvmId);
        assertTrue(ok);
        assertTrue(hook.paused());
        assertEq(callback.lastRoundId(feed2), 1, "rounds are tracked per aggregator");
        assertEq(callback.lastRoundId(feed), 0);
    }

    function test_reactRefusesUnexpectedLog() public {
        IReactive.LogRecord memory wrongChain = logRecord(0.5e8, 1);
        wrongChain.chain_id = 1;
        vm.prank(rvmId, rvmId);
        vm.expectRevert(OrbitalDepegReactive.UnexpectedLog.selector);
        reactive.react(wrongChain);

        IReactive.LogRecord memory wrongTopic = logRecord(0.5e8, 1);
        wrongTopic.topic_0 = uint256(keccak256("Transfer(address,address,uint256)"));
        vm.prank(rvmId, rvmId);
        vm.expectRevert(OrbitalDepegReactive.UnexpectedLog.selector);
        reactive.react(wrongTopic);
        assertEq(reactive.ANSWER_UPDATED_TOPIC(), logRecord(0, 0).topic_0);
    }

    function test_reactiveConfigValidation() public {
        vm.expectRevert(OrbitalDepegReactive.InvalidConfig.selector);
        new OrbitalDepegReactive(ORIGIN_CHAIN, address(0), DEST_CHAIN, address(callback), 1, PEG, BAND_BPS);
        vm.expectRevert(OrbitalDepegReactive.InvalidConfig.selector);
        new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 1, 0, BAND_BPS);
        vm.expectRevert(OrbitalDepegReactive.InvalidConfig.selector);
        new OrbitalDepegReactive(ORIGIN_CHAIN, feed, DEST_CHAIN, address(callback), 1, PEG, 10_000);
    }

    function test_reactiveSubscribeManagementIsNetworkOnly() public {
        assertTrue(reactive.isReactVm());
        vm.prank(rvmId);
        vm.expectRevert(OrbitalDepegReactive.ReactiveNetworkOnly.selector);
        reactive.subscribe();
        vm.prank(rvmId);
        vm.expectRevert(OrbitalDepegReactive.ReactiveNetworkOnly.selector);
        reactive.setFeed(makeAddr("x"));
        vm.prank(trader);
        vm.expectRevert(OrbitalDepegReactive.NotOwner.selector);
        reactive.unsubscribe();
    }

    function test_reactivePaymentHooks() public {
        vm.deal(address(reactive), 1 ether);
        vm.expectRevert(OrbitalDepegReactive.NotSystemContract.selector);
        reactive.pay(1);
        vm.prank(SERVICE);
        reactive.pay(0.25 ether);
        assertEq(address(reactive).balance, 0.75 ether);
        vm.prank(trader);
        vm.expectRevert(OrbitalDepegReactive.NotOwner.selector);
        reactive.withdraw(payable(trader), 1);
        vm.prank(rvmId);
        reactive.withdraw(payable(trader), 0.5 ether);
        assertEq(trader.balance, 0.5 ether);
    }

    // ---- failure paths: callback side -------------------------------------------------------

    function test_callbackRefusesNonProxy() public {
        vm.expectRevert(OrbitalDepegCallback.NotCallbackProxy.selector);
        callback.depeg(rvmId, feed, 0.5e8, 1);
        assertFalse(hook.paused());
    }

    function test_callbackRefusesWrongRvmId() public {
        (bytes memory payload,) = reactAndCapture(0.5e8, 1);
        (bool ok, bytes memory ret) = proxy.deliver(address(callback), payload, makeAddr("impostor"));
        assertFalse(ok);
        assertEq(bytes4(ret), OrbitalDepegCallback.WrongRvmId.selector);
        assertFalse(hook.paused());
        // A zero id is never accepted, even if misconfigured to zero.
        vm.prank(owner);
        callback.setRvmId(address(0));
        (ok, ret) = proxy.deliver(address(callback), payload, address(0));
        assertFalse(ok);
        assertEq(bytes4(ret), OrbitalDepegCallback.WrongRvmId.selector);
    }

    function test_callbackFailsWhenNotGuardian() public {
        vm.prank(owner);
        hook.setGuardian(address(0));
        (bytes memory payload,) = reactAndCapture(0.5e8, 1);
        (bool ok, bytes memory ret) = proxy.deliver(address(callback), payload, rvmId);
        assertFalse(ok, "hook refuses a callback that is not its guardian");
        assertEq(bytes4(ret), OrbitalHook.NotGuardian.selector);
    }

    function test_callbackAdminAndPayment() public {
        vm.prank(trader);
        vm.expectRevert(OrbitalDepegCallback.NotOwner.selector);
        callback.setRvmId(trader);
        vm.prank(trader);
        vm.expectRevert(OrbitalDepegCallback.NotOwner.selector);
        callback.withdraw(payable(trader), 1);

        vm.expectRevert(OrbitalDepegCallback.NotCallbackProxy.selector);
        callback.pay(1);
        proxy.charge(address(callback), 0.1 ether);
        assertEq(address(proxy).balance, 0.1 ether);

        vm.prank(owner);
        callback.withdraw(payable(owner), 0.4 ether);
        assertEq(owner.balance, 0.4 ether);
        assertEq(address(callback).balance, 0.5 ether);

        vm.prank(owner);
        callback.transferOwnership(trader);
        assertEq(callback.owner(), trader);
    }

    function test_callbackConstructionAndHookBinding() public {
        vm.expectRevert(OrbitalDepegCallback.ZeroAddress.selector);
        new OrbitalDepegCallback(address(0), address(hook), rvmId);

        // Deployed before the hook exists: the deployer owns it and binds the hook exactly once.
        OrbitalDepegCallback unbound = new OrbitalDepegCallback(address(proxy), address(0), rvmId);
        assertEq(unbound.owner(), address(this));
        (bytes memory payload,) = reactAndCapture(0.5e8, 1);
        (bool ok, bytes memory ret) = proxy.deliver(address(unbound), payload, rvmId);
        assertFalse(ok);
        assertEq(bytes4(ret), OrbitalDepegCallback.HookNotSet.selector);

        vm.prank(trader);
        vm.expectRevert(OrbitalDepegCallback.NotOwner.selector);
        unbound.setHook(address(hook));
        vm.expectRevert(OrbitalDepegCallback.ZeroAddress.selector);
        unbound.setHook(address(0));
        unbound.setHook(address(hook));
        assertEq(address(unbound.hook()), address(hook));
        vm.expectRevert(OrbitalDepegCallback.HookAlreadySet.selector);
        unbound.setHook(address(hook));
        vm.expectRevert(OrbitalDepegCallback.ZeroAddress.selector);
        unbound.transferOwnership(address(0));
    }

    function slice(bytes memory data, uint256 start) internal pure returns (bytes memory out) {
        out = new bytes(data.length - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[start + i];
        }
    }
}
