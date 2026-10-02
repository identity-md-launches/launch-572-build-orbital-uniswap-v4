// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {OrbitalToken} from "../../src/OrbitalToken.sol";

/// @notice Moves ORB between a fixed set of holders with transfers, approvals and transferFroms;
/// refusals (insufficient balance/allowance, zero recipient) are the expected answer and are caught.
contract OrbitalTokenHandler is Test {
    OrbitalToken public token;
    address[] public holders;
    uint256 public transfersOk;
    uint256 public transfersRefused;

    constructor(OrbitalToken _token, address[] memory _holders) {
        token = _token;
        holders = _holders;
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = holders[fromSeed % holders.length];
        address to = toSeed % 7 == 0 ? address(0) : holders[toSeed % holders.length];
        uint256 bal = token.balanceOf(from);
        amount = bound(amount, 0, bal + 1); // sometimes one more than held
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            assertTrue(ok, "transfer returned false");
            assertTrue(to != address(0), "transfer to zero succeeded");
            assertLe(amount, bal, "overdraw succeeded");
            assertEq(token.balanceOf(from), from == to ? bal : bal - amount, "sender balance");
            assertEq(token.balanceOf(to), from == to ? toBefore : toBefore + amount, "recipient balance");
            transfersOk++;
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (to == address(0)) assertEq(sel, OrbitalToken.ZeroAddress.selector, "zero recipient reason");
            else assertEq(sel, OrbitalToken.InsufficientBalance.selector, "overdraw reason");
            assertEq(token.balanceOf(from), bal, "refused transfer moved tokens");
            transfersRefused++;
        }
    }

    function approveAndTransferFrom(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 toSeed,
        uint256 allowed,
        uint256 amount
    ) external {
        address owner = holders[ownerSeed % holders.length];
        address spender = holders[spenderSeed % holders.length];
        address to = holders[toSeed % holders.length];
        uint256 bal = token.balanceOf(owner);
        allowed = bound(allowed, 0, bal + 1);
        if (allowed == bal + 1) allowed = type(uint256).max; // infinite approval path
        amount = bound(amount, 0, bal + 1);
        vm.prank(owner);
        token.approve(spender, allowed);
        assertEq(token.allowance(owner, spender), allowed);

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) returns (bool ok) {
            assertTrue(ok);
            assertLe(amount, bal, "overdraw via transferFrom");
            assertLe(amount, allowed, "spent beyond allowance");
            if (allowed == type(uint256).max) {
                assertEq(token.allowance(owner, spender), type(uint256).max, "infinite allowance consumed");
            } else {
                assertEq(token.allowance(owner, spender), allowed - amount, "allowance not decremented");
            }
            transfersOk++;
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (amount > allowed) assertEq(sel, OrbitalToken.InsufficientAllowance.selector, "allowance reason");
            else assertEq(sel, OrbitalToken.InsufficientBalance.selector, "balance reason");
            assertEq(token.balanceOf(owner), bal, "refused transferFrom moved tokens");
            transfersRefused++;
        }
    }
}

contract OrbitalTokenInvariantTest is StdInvariant, Test {
    OrbitalToken token;
    OrbitalTokenHandler handler;
    address[] holders;

    function setUp() public {
        token = new OrbitalToken();
        holders.push(address(this));
        for (uint256 i = 0; i < 4; i++) {
            address h = makeAddr(string(abi.encodePacked("holder", i)));
            holders.push(h);
            token.transfer(h, 1_000_000 ether * (i + 1));
        }
        handler = new OrbitalTokenHandler(token, holders);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyIsFixed() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < holders.length; i++) {
            sum += token.balanceOf(holders[i]);
        }
        assertEq(sum, token.totalSupply(), "balances do not sum to supply");
        assertEq(token.balanceOf(address(0)), 0, "zero address holds tokens");
    }
}
