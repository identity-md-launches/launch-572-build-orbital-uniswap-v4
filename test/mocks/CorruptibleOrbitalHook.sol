// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {OrbitalHook} from "../../src/OrbitalHook.sol";

/// @notice Test-only subclass that can move the virtual reserves off the torus, to exercise the
/// hook's start-of-trade fail-safe. No production path can do this.
contract CorruptibleOrbitalHook is OrbitalHook {
    constructor(
        IPoolManager _poolManager,
        address _owner,
        address _guardian,
        address[] memory basket,
        uint8[] memory decimals,
        uint256[] memory kNorms,
        uint24 _feePpm
    ) OrbitalHook(_poolManager, _owner, _guardian, basket, decimals, kNorms, _feePpm) {}

    function nudgeReserve(uint256 k, int256 delta) external {
        _x[k] = uint256(int256(_x[k]) + delta);
    }
}
