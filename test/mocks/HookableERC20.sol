// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Mintable ERC-20 for tests with configurable decimals and two switches real stablecoins
/// have: an issuer pause (transfers revert) and a receiver notification on transfer (as ERC-777 /
/// ERC-1363 style tokens do), which is how a transfer can re-enter the caller.
contract HookableERC20 {
    uint8 public immutable decimals;
    bool public paused;
    bool public notify;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(uint8 d) {
        decimals = d;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function setNotify(bool v) external {
        notify = v;
    }

    function mint(address to, uint256 a) external {
        totalSupply += a;
        balanceOf[to] += a;
        emit Transfer(address(0), to, a);
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        emit Approval(msg.sender, s, a);
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        _move(f, to, a);
        return true;
    }

    function _move(address f, address to, uint256 a) internal {
        require(!paused, "paused");
        balanceOf[f] -= a;
        balanceOf[to] += a;
        emit Transfer(f, to, a);
        if (notify && to.code.length > 0) {
            (bool ok,) = to.call(abi.encodeWithSignature("onTokenReceived(address,uint256)", f, a));
            ok; // a recipient without the hook is fine
        }
    }
}
