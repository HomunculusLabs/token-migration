// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Worthless, public faucet fixture for Base Sepolia migration exercises, never a real asset.
/// @dev No privileged minter: anyone can exhaust the test supply. Redeploy for another exercise.
contract TestnetV1 is ERC20 {
    error WrongChain();
    error FaucetLimit();

    uint256 public constant MAX_MINT = 1000 ether;
    uint256 public constant MAX_SUPPLY = 1_000_000 ether;

    constructor() ERC20("TEST ONLY Surplus V1", "TEST-V1") {
        if (block.chainid != 84532) revert WrongChain();
    }

    function faucet(address to, uint256 amount) external {
        if (amount == 0 || amount > MAX_MINT || totalSupply() + amount > MAX_SUPPLY) revert FaucetLimit();
        _mint(to, amount);
    }
}
