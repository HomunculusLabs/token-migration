// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev Minimal ERC-20 double for the migration suites: mint, allowance and a well-behaved
 *      `transfer`/`transferFrom` returning `true`. The vault talks to tokens only through
 *      OpenZeppelin's SafeERC20, whose non-standard-return handling is exercised by OZ's own
 *      suites; what these tests need is plain supply/allowance bookkeeping. Declaring `is IERC20`
 *      makes any interface drift a compile error at the mock, not a mystery cast failure.
 */
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "insufficient");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(balanceOf[from] >= value, "insufficient");
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "insufficient allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }

    /// @dev Test-only: fund the vault's v2 backing, reverting on any failure — the erc20-unchecked
    ///      lint exists because an ignored `false` return is a silent loss; a helper that reverts
    ///      internally is the checked form for a mock. (Note: cannot delegate via `this.transfer` —
    ///      the external self-call would rebind msg.sender to the mock and break balances.)
    function checkedTransfer(address to, uint256 value) external {
        require(balanceOf[msg.sender] >= value, "insufficient");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
    }
}
