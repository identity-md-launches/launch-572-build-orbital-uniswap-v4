// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {OrbitalHook} from "../src/OrbitalHook.sol";
import {OrbitalToken} from "../src/OrbitalToken.sol";
import {OrbitalDepegCallback} from "../src/reactive/OrbitalDepegCallback.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @title DeployOrbital
/// @notice Deploys the ORB launch token, the Orbital hook at a mined CREATE2 address and the
/// Reactive depeg callback, then wires the callback in as the hook's guardian.
/// @dev `deploy` is pure configuration-in, addresses-out so tests exercise it directly. `run`
/// only reads the environment and forwards; nothing here hardcodes a chain address.
contract DeployOrbital is Script {
    /// @dev Foundry's default deterministic CREATE2 deployer, used when broadcasting `new{salt:}`.
    address public constant DEFAULT_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 public constant HOOK_FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_ADD_LIQUIDITY
        | HookFlags.BEFORE_SWAP | HookFlags.BEFORE_SWAP_RETURN_DELTA;

    struct Config {
        IPoolManager poolManager; // the destination chain's PoolManager ("$poolManager")
        address owner; // hook owner (multisig recommended)
        address[] basket; // stablecoins on the sphere
        uint8[] decimals; // their decimals, in the same order
        uint256[] kNorms; // tick planes per unit radius (WAD), ascending
        uint24 feePpm; // swap fee, parts per million
        address callbackProxy; // Reactive callback proxy on this chain
        address rvmId; // deployer EOA of OrbitalDepegReactive on Reactive Lasna
        address create2Deployer; // who executes CREATE2 (this contract in tests, 0x4e59… in broadcast)
    }

    struct Deployed {
        OrbitalToken token;
        OrbitalHook hook;
        OrbitalDepegCallback callback;
        bytes32 salt;
    }

    error NoSaltFound();

    function run() external returns (Deployed memory d) {
        Config memory cfg;
        cfg.poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        cfg.owner = vm.envAddress("OWNER");
        cfg.basket = vm.envAddress("BASKET", ",");
        cfg.decimals = toUint8(vm.envUint("DECIMALS", ","));
        cfg.kNorms = vm.envUint("K_NORMS", ",");
        cfg.feePpm = uint24(vm.envUint("FEE_PPM"));
        cfg.callbackProxy = vm.envAddress("CALLBACK_PROXY");
        cfg.rvmId = vm.envAddress("RVM_ID");
        cfg.create2Deployer = DEFAULT_CREATE2_DEPLOYER;
        vm.startBroadcast();
        d = deploy(cfg);
        vm.stopBroadcast();
    }

    /// @notice Deploys everything. The hook's guardian is the callback; ownership of the hook ends
    /// at `cfg.owner`, and the ORB supply ends with the broadcaster (this contract in tests).
    function deploy(Config memory cfg) public returns (Deployed memory d) {
        d.token = new OrbitalToken();

        // The hook is first owned by the script so the guardian can be wired, then handed over.
        bytes memory creationCode = abi.encodePacked(
            type(OrbitalHook).creationCode,
            abi.encode(cfg.poolManager, address(this), address(0), cfg.basket, cfg.decimals, cfg.kNorms, cfg.feePpm)
        );
        d.salt = mineSalt(cfg.create2Deployer, creationCode, HOOK_FLAGS);
        d.hook = new OrbitalHook{salt: d.salt}(
            cfg.poolManager, address(this), address(0), cfg.basket, cfg.decimals, cfg.kNorms, cfg.feePpm
        );

        d.callback = new OrbitalDepegCallback(cfg.callbackProxy, address(d.hook), cfg.rvmId, cfg.owner);
        d.hook.setGuardian(address(d.callback));
        d.hook.transferOwnership(cfg.owner);
    }

    function toUint8(uint256[] memory xs) internal pure returns (uint8[] memory out) {
        out = new uint8[](xs.length);
        for (uint256 i = 0; i < xs.length; i++) {
            out[i] = uint8(xs[i]);
        }
    }

    /// @notice Finds a CREATE2 salt placing `creationCode` on an address with exactly `flags`.
    function mineSalt(address deployer, bytes memory creationCode, uint160 flags) public pure returns (bytes32) {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 500_000; i++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initCodeHash))))
            );
            if (HookFlags.matches(predicted, flags)) return bytes32(i);
        }
        revert NoSaltFound();
    }
}
