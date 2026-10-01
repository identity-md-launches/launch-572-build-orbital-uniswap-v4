// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {DeployOrbital} from "../script/DeployOrbital.s.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeployTest is Test {
    function test_deployWiresEverything() public {
        PoolManager manager = new PoolManager(address(this));
        DeployOrbital script = new DeployOrbital();

        address[] memory basket = new address[](2);
        basket[0] = address(new MockERC20("A", "A", 0));
        basket[1] = address(new MockERC20("B", "B", 0));
        uint8[] memory decs = new uint8[](2);
        decs[0] = 18;
        decs[1] = 18;
        uint256[] memory ks = new uint256[](2);
        ks[0] = 0.5e18; // N = 2: range is (√2 − 1, 1/√2]
        ks[1] = 0.7e18;

        DeployOrbital.Config memory cfg = DeployOrbital.Config({
            poolManager: IPoolManager(address(manager)),
            owner: makeAddr("multisig"),
            basket: basket,
            decimals: decs,
            kNorms: ks,
            feePpm: 300,
            callbackProxy: makeAddr("reactive-callback-proxy"),
            rvmId: makeAddr("reactive-deployer"),
            create2Deployer: address(script)
        });
        DeployOrbital.Deployed memory d = script.deploy(cfg);

        assertTrue(HookFlags.matches(address(d.hook), script.HOOK_FLAGS()), "mined address carries the flags");
        assertEq(address(d.hook.poolManager()), address(manager));
        assertEq(d.hook.owner(), cfg.owner, "ownership handed to the multisig");
        assertEq(d.hook.guardian(), address(d.callback), "callback is the guardian");
        assertEq(d.hook.feePpm(), 300);
        assertEq(d.hook.levelCount(), 2);
        assertEq(address(d.callback.hook()), address(d.hook));
        assertEq(d.callback.callbackProxy(), cfg.callbackProxy);
        assertEq(d.callback.rvmId(), cfg.rvmId);
        assertEq(d.callback.owner(), cfg.owner);
        assertEq(d.token.totalSupply(), 1e27);
        assertEq(d.token.balanceOf(address(script)), 1e27, "supply minted to the deployer");
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
