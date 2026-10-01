// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OrbitalToken} from "../src/OrbitalToken.sol";

contract OrbitalTokenTest is Test {
    OrbitalToken token;
    address alice = makeAddr("alice");

    function setUp() public {
        token = new OrbitalToken();
    }

    function test_fixedSupplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "Orbital");
        assertEq(token.symbol(), "ORB");
    }

    function test_transferMovesExactly() public {
        assertTrue(token.transfer(alice, 1_000 ether));
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 1_000 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferFromRespectsAllowance() public {
        token.approve(alice, 5 ether);
        vm.prank(alice);
        vm.expectRevert(OrbitalToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), alice, 6 ether);
        vm.prank(alice);
        assertTrue(token.transferFrom(address(this), alice, 5 ether));
        assertEq(token.allowance(address(this), alice), 0);
        assertEq(token.balanceOf(alice), 5 ether);
    }

    function test_transferFailures() public {
        vm.prank(alice);
        vm.expectRevert(OrbitalToken.InsufficientBalance.selector);
        token.transfer(address(this), 1);
        vm.expectRevert(OrbitalToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    function test_noMintOrAdminSurface() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("transferOwnership(address)", alice));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1e27);
    }
}
