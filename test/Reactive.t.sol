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
        callback = new OrbitalDepegCallback(address(proxy), address(hook), rvmId, owner);
        vm.prank(owner);
        hook.setGuardian(address(callback));
        // The system contract has no code in this test, so the contract believes it is in a ReactVM
        // (no subscribe call), which is also how it behaves inside a real RVM.
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

    /// @dev Runs `react` and returns the payload of the emitted `Callback`, or empty when none.
    function reactAndCapture(int256 price, uint256 roundId) internal returns (bytes memory payload, bool emitted) {
        IReactive.LogRecord memory rec = logRecord(price, roundId);
        vm.recordLogs();
        vm.prank(SERVICE);
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

    // ---- end to end -------------------------------------------------------------------------

    function test_depegPausesThePoolEndToEnd() public {
        assertFalse(hook.paused());
        (bytes memory payload, bool emitted) = reactAndCapture(0.97e8, 42);
        assertTrue(emitted, "callback requested");
        assertEq(bytes4(payload), bytes4(keccak256("depeg(address,address,int256,uint256)")));

        vm.expectEmit(true, false, false, true, address(callback));
        emit OrbitalDepegCallback.DepegPauseTriggered(feed, 0.97e8, 42);
        (bool ok,) = proxy.deliver(address(callback), payload, rvmId);
        assertTrue(ok, "delivery succeeded");
        assertTrue(hook.paused(), "pool paused by the breaker");

        vm.expectRevert();
        swapAs(trader, keyAB, true, -1e18);

        // A second delivery is harmless, and only the owner can resume.
        (ok,) = proxy.deliver(address(callback), payload, rvmId);
        assertTrue(ok);
        vm.prank(owner);
        hook.unpause();
        assertFalse(hook.paused());
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
        (, emitted) = reactAndCapture(-1, 2);
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

    function test_reactRefusesNonSystemCaller() public {
        IReactive.LogRecord memory rec = logRecord(0.5e8, 1);
        vm.expectRevert(OrbitalDepegReactive.NotSystemContract.selector);
        reactive.react(rec);
        assertEq(reactive.ANSWER_UPDATED_TOPIC(), rec.topic_0);
    }

    function test_reactRefusesUnexpectedLog() public {
        IReactive.LogRecord memory wrongFeed = logRecord(0.5e8, 1);
        wrongFeed._contract = makeAddr("other-feed");
        vm.prank(SERVICE);
        vm.expectRevert(OrbitalDepegReactive.UnexpectedLog.selector);
        reactive.react(wrongFeed);

        IReactive.LogRecord memory wrongChain = logRecord(0.5e8, 1);
        wrongChain.chain_id = 1;
        vm.prank(SERVICE);
        vm.expectRevert(OrbitalDepegReactive.UnexpectedLog.selector);
        reactive.react(wrongChain);

        IReactive.LogRecord memory wrongTopic = logRecord(0.5e8, 1);
        wrongTopic.topic_0 = uint256(keccak256("Transfer(address,address,uint256)"));
        vm.prank(SERVICE);
        vm.expectRevert(OrbitalDepegReactive.UnexpectedLog.selector);
        reactive.react(wrongTopic);
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
        vm.expectRevert(OrbitalDepegReactive.ReactiveNetworkOnly.selector);
        reactive.subscribe();
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

    function test_callbackConstructorChecks() public {
        vm.expectRevert(OrbitalDepegCallback.ZeroAddress.selector);
        new OrbitalDepegCallback(address(0), address(hook), rvmId, owner);
        vm.expectRevert(OrbitalDepegCallback.ZeroAddress.selector);
        new OrbitalDepegCallback(address(proxy), address(0), rvmId, owner);
        vm.expectRevert(OrbitalDepegCallback.ZeroAddress.selector);
        new OrbitalDepegCallback(address(proxy), address(hook), rvmId, address(0));
    }
}
