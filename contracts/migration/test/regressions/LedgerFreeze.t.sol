// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationVault} from "../../src/MigrationVault.sol";
import {ReviewFindingsBase} from "./ReviewFindingsBase.sol";

/// @dev P1, P1b, P2 and P7 share one fix: the ledger freezes at the deposit deadline, and a
///      permissionless commit deadline stops the freeze from trapping deposits behind a silent Safe.
contract LedgerFreezeTest is ReviewFindingsBase {
    bytes4 internal constant COMMIT_WINDOW_STILL_OPEN = bytes4(keccak256("CommitWindowStillOpen(uint256,uint256)"));
    bytes4 internal constant COMMIT_WINDOW_CLOSED = bytes4(keccak256("CommitWindowClosed(uint256,uint256)"));

    /// P1: a withdrawal between the deposit deadline and commitRoot let a holder be in the root
    /// AND have their v1 back.
    function test_P1_WithdrawalAfterDepositDeadlineIsRejected() public {
        MigrationVault vault = _vault(false, 10_000);
        _deposit(vault, alice, 100 ether);
        _deposit(vault, bob, 100 ether);
        vm.warp(vault.DEPOSIT_DEADLINE() + 1);
        bytes32 root = _root(_leaves2(alice, 100 ether, bob, 100 ether)); // the operator's snapshot

        vm.prank(alice);
        vm.expectRevert(MigrationVault.LedgerWithdrawalsFrozen.selector);
        vault.withdrawV1(100 ether);

        vault.commitRoot(root, 200 ether);
        v2.mint(address(vault), 200 ether);
        vault.activateClaims();
        assertEq(v1.balanceOf(address(vault)), 200 ether, "every leaf is backed by deposited v1");
        assertEq(v1.balanceOf(alice), 0, "alice kept nothing back");
    }

    /// P1b: the same hole on the timeout path paid the early withdrawer twice and left the last
    /// depositor with nothing.
    function test_P1b_TimeoutPathPaysEachDepositorExactlyOnce() public {
        MigrationVault vault = _vault(false, 10_000);
        _deposit(vault, alice, 100 ether);
        _deposit(vault, bob, 100 ether);
        vm.warp(vault.DEPOSIT_DEADLINE() + 1);

        vm.prank(alice);
        vm.expectRevert(MigrationVault.LedgerWithdrawalsFrozen.selector);
        vault.withdrawV1(100 ether);

        vault.commitRoot(_root(_leaves2(alice, 100 ether, bob, 100 ether)), 200 ether);
        vm.warp(vault.rootCommittedAt() + EXECUTION_WINDOW + 1);
        vault.expireExecution();
        vm.startPrank(relayer);
        _hardened(vault).refund(alice);
        _hardened(vault).refund(bob);
        vm.stopPrank();
        assertEq(v1.balanceOf(alice), 100 ether, "alice exits once");
        assertEq(v1.balanceOf(bob), 100 ether, "bob is made whole");
        assertEq(v1.balanceOf(address(vault)), 0, "nothing stranded");
    }

    /// P2: with pro-rata on, a 1-wei withdrawal in front of the Safe's commitRoot bricked the
    /// commit, because the total no longer matched.
    function test_P2_OneWeiWithdrawalCannotBrickCommit() public {
        MigrationVault vault = _vault(true, 10_000);
        _deposit(vault, alice, 100 ether);
        _deposit(vault, bob, 100 ether);
        vm.warp(vault.DEPOSIT_DEADLINE() + 1);

        vm.prank(bob);
        vm.expectRevert(MigrationVault.LedgerWithdrawalsFrozen.selector);
        vault.withdrawV1(1);

        vault.commitRoot(_root(_leaves2(alice, 100 ether, bob, 100 ether)), 200 ether);
        assertEq(uint8(vault.phase()), uint8(MigrationVault.Phase.Committed), "the commit went through");
    }

    /// P7: freezing alone would trap every deposit behind a Safe that never commits. Past the
    /// commit deadline anyone can cancel, and a relayer can refund every depositor.
    function test_P7_PreCommitTimeoutRefundsEveryDepositor() public {
        MigrationVault vault = _vault(false, 10_000);
        _deposit(vault, alice, 100 ether);
        _deposit(vault, bob, 40 ether);
        vm.warp(vault.DEPOSIT_DEADLINE() + COMMIT_WINDOW + 1); // the Safe went silent

        vm.prank(relayer);
        _hardened(vault).expireCommit();
        assertEq(uint8(vault.phase()), uint8(MigrationVault.Phase.Cancelled), "cancelled permissionlessly");

        vm.startPrank(relayer);
        _hardened(vault).refund(alice);
        _hardened(vault).refund(bob);
        vm.stopPrank();
        assertEq(v1.balanceOf(alice), 100 ether, "alice refunded");
        assertEq(v1.balanceOf(bob), 40 ether, "bob refunded");
        assertEq(v1.balanceOf(address(vault)), 0, "nothing trapped");
    }

    function test_CommitDeadlineIsHardForTheSafe() public {
        MigrationVault vault = _vault(false, 10_000);
        _deposit(vault, alice, 100 ether);
        uint256 commitDeadline = vault.DEPOSIT_DEADLINE() + COMMIT_WINDOW;
        assertEq(_hardened(vault).COMMIT_DEADLINE(), commitDeadline, "commit deadline");

        vm.warp(commitDeadline);
        vm.expectRevert(abi.encodeWithSelector(COMMIT_WINDOW_STILL_OPEN, commitDeadline, commitDeadline));
        _hardened(vault).expireCommit();

        vm.warp(commitDeadline + 1);
        bytes32 root = _root(_leaves2(alice, 100 ether, bob, 0));
        vm.expectRevert(abi.encodeWithSelector(COMMIT_WINDOW_CLOSED, commitDeadline, commitDeadline + 1));
        vault.commitRoot(root, 100 ether);
    }

    function test_WithdrawalBeforeTheDeadlineStillWorks() public {
        MigrationVault vault = _vault(false, 10_000);
        _deposit(vault, alice, 100 ether);
        vm.warp(vault.DEPOSIT_DEADLINE());
        vm.prank(alice);
        vault.withdrawV1(100 ether);
        assertEq(v1.balanceOf(alice), 100 ether, "change of mind up to the deadline");
    }
}
