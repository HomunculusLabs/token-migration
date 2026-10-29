// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationVault} from "../../src/MigrationVault.sol";
import {ReviewFindingsBase} from "./ReviewFindingsBase.sol";

/// @dev P6: v1 sent to the vault by plain transfer had no way out.
contract PlainTransferRescueTest is ReviewFindingsBase {
    bytes4 internal constant NOTHING_TO_RESCUE = bytes4(keccak256("NothingToRescue()"));

    function test_P6_PlainTransferIsRescuableButDepositsAreNot() public {
        MigrationVault vault = _vault(false, 10_000);
        _deposit(vault, alice, 100 ether);
        v1.mint(bob, 50 ether);
        vm.prank(bob);
        v1.checkedTransfer(address(vault), 50 ether);
        assertEq(vault.availableToWithdraw(bob), 0, "a plain transfer earns no credit");

        _hardened(vault).rescueV1(bob);
        assertEq(v1.balanceOf(bob), 50 ether, "bob's mistaken transfer returned");
        assertEq(v1.balanceOf(address(vault)), 100 ether, "alice's deposit untouched");

        vm.expectRevert(NOTHING_TO_RESCUE);
        _hardened(vault).rescueV1(bob);
    }

    function test_RescueNeverReachesDepositsInAnyPhase() public {
        MigrationVault vault = _vault(false, 10_000);
        _deposit(vault, alice, 100 ether);
        v1.mint(bob, 5 ether);
        vm.prank(bob);
        v1.checkedTransfer(address(vault), 5 ether);
        vm.warp(vault.DEPOSIT_DEADLINE() + 1);
        vault.commitRoot(_root(_leaves2(alice, 100 ether, bob, 0)), 100 ether);
        vm.warp(vault.rootCommittedAt() + EXECUTION_WINDOW + 1);
        vault.expireExecution();

        _hardened(vault).rescueV1(bob); // the 5 excess, even mid-refund
        _hardened(vault).refund(alice);
        assertEq(v1.balanceOf(alice), 100 ether, "alice's refund is intact");
        assertEq(v1.balanceOf(bob), 5 ether, "only the excess was rescued");
    }

    function test_RevertIf_RescueByOutsider() public {
        MigrationVault vault = _vault(false, 10_000);
        vm.prank(bob);
        vm.expectRevert(MigrationVault.NotOwner.selector);
        _hardened(vault).rescueV1(bob);
    }
}
