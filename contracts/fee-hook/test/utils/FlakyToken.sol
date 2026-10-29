// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev ERC-20-shaped double whose transfer succeeds, returns false, reverts, or returns nothing (USDT-style).
contract FlakyToken {
    enum Mode {
        ReturnTrue,
        ReturnFalse,
        Revert,
        ReturnNothing
    }

    Mode public mode;
    mapping(address => uint256) public balanceOf;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (mode == Mode.Revert) revert("FlakyToken: revert");
        if (mode == Mode.ReturnFalse) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (mode == Mode.ReturnNothing) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }
}
