// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {DeployOrbital} from "../script/DeployOrbital.s.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeployTest is Test {
    function config(PoolManager manager, address create2Deployer) internal returns (DeployOrbital.Config memory) {
        address[] memory basket = new address[](2);
        basket[0] = address(new MockERC20("A", "A", 0));
        basket[1] = address(new MockERC20("B", "B", 0));
        uint8[] memory decs = new uint8[](2);
        decs[0] = 18;
        decs[1] = 18;
        uint256[] memory ks = new uint256[](2);
        ks[0] = 0.5e18; // N = 2: range is (√2 − 1, 1/√2]
        ks[1] = 0.7e18;
        return DeployOrbital.Config({
            poolManager: IPoolManager(address(manager)),
            owner: makeAddr("multisig"),
            basket: basket,
            decimals: decs,
            kNorms: ks,
            feePpm: 300,
            callbackProxy: makeAddr("reactive-callback-proxy"),
            rvmId: makeAddr("reactive-deployer"),
            create2Deployer: create2Deployer
        });
    }

    function check(
        DeployOrbital script,
        DeployOrbital.Config memory cfg,
        DeployOrbital.Deployed memory d,
        address deployer
    ) internal view {
        assertTrue(HookFlags.matches(address(d.hook), script.HOOK_FLAGS()), "mined address carries the flags");
        assertEq(address(d.hook.poolManager()), address(cfg.poolManager));
        assertEq(d.hook.owner(), cfg.owner, "hook owned by the multisig from its constructor");
        assertEq(d.hook.guardian(), address(d.callback), "callback is the guardian from the constructor");
        assertEq(d.hook.feePpm(), 300);
        assertEq(d.hook.levelCount(), 2);
        assertEq(address(d.callback.hook()), address(d.hook), "callback bound to the hook");
        assertEq(d.callback.callbackProxy(), cfg.callbackProxy);
        assertEq(d.callback.rvmId(), cfg.rvmId);
        assertEq(d.callback.owner(), cfg.owner, "callback handed to the multisig");
        assertEq(d.token.totalSupply(), 1e27);
        assertEq(d.token.balanceOf(deployer), 1e27, "supply minted to the deployer");
    }

    function test_deployWiresEverything() public {
        PoolManager manager = new PoolManager(address(this));
        DeployOrbital script = new DeployOrbital();
        DeployOrbital.Config memory cfg = config(manager, address(script));
        DeployOrbital.Deployed memory d = script.deploy(cfg);
        check(script, cfg, d, address(script));
    }

    function test_mineSaltFindsMatchingAddress() public {
        DeployOrbital script = new DeployOrbital();
        bytes memory code = hex"600a600c600039600a6000f3602a60005260206000f3";
        bytes32 salt = script.mineSalt(address(this), code, HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP);
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(code))))));
        assertTrue(HookFlags.matches(predicted, HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP));
    }
}

/// @notice The same `deploy` under `vm.startBroadcast`, where every call the script makes is sent
/// from the broadcaster EOA and `new{salt:}` goes through the default CREATE2 deployer, exactly as
/// `forge script --broadcast` does. No owner-only call on the hook is needed.
contract DeployBroadcastTest is DeployTest, DeployOrbital {
    function test_deployUnderBroadcast() public {
        PoolManager manager = new PoolManager(address(this));
        Config memory cfg = config(manager, DEFAULT_CREATE2_DEPLOYER);
        address broadcaster = makeAddr("broadcaster");
        vm.deal(broadcaster, 1 ether);
        vm.startBroadcast(broadcaster);
        Deployed memory d = deploy(cfg);
        vm.stopBroadcast();
        check(this, cfg, d, broadcaster);
    }
}
