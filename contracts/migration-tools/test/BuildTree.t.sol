// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BuildTree} from "../script/BuildTree.s.sol";
import {Test} from "migration/test/Base.t.sol";

/// @dev Exposes BuildTree's duplicate-account table, which run() fills one deposits.csv row at a time.
contract DupTableHarness is BuildTree {
    function insert(address a, uint256 row) external {
        _insert(a, row);
    }

    /// @dev `count` distinct accounts as rows 0..count-1.
    function insertMany(uint256 count) external {
        for (uint256 i; i < count; ++i) {
            _insert(account(i), i);
        }
    }

    function account(uint256 i) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("dup-table", i)))));
    }
}

/**
 * @title BuildTreeTest
 * @notice BuildTree's duplicate-account table at the size the launch kit relies on: more rows than the
 *         old 65,536-slot table held still load, and a repeated account is still caught past that point.
 */
contract BuildTreeTest is Test {
    uint256 internal constant OLD_TABLE_SIZE = 1 << 16;

    DupTableHarness internal tree;

    function setUp() public {
        tree = new DupTableHarness();
    }

    function test_DupTable_TakesMoreRowsThanTheOldTable() public {
        tree.insertMany(OLD_TABLE_SIZE + 1); // the old table reverted TableFull() on this row
    }

    function test_DupTable_RejectsARepeatPastTheOldTable() public {
        tree.insertMany(OLD_TABLE_SIZE + 1);
        address again = tree.account(7);
        vm.expectRevert(abi.encodeWithSelector(BuildTree.DuplicateAccount.selector, again, OLD_TABLE_SIZE + 1));
        tree.insert(again, OLD_TABLE_SIZE + 1);
    }
}
