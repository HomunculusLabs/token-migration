// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationVault} from "../../src/MigrationVault.sol";
import {MockERC20} from "../MockERC20.sol";
import {ReviewFindingsBase} from "./ReviewFindingsBase.sol";

/// @dev Spec §3.5 oracle review of the vault diff (aeab69988..b62393184). Each test reproduces a finding
///      that was REAL on that commit and FAILS there; kit/evidence/review/migration-oracle.md has the triage.
///      Either fix shape passes: the vault refuses the input, or it honours the deal it accepted.
contract OracleReviewTest is ReviewFindingsBase {
    /// Oracle round 1, finding 1. EXECUTION_WINDOW is published as the time the Safe has to activate
    /// claims, after which "anyone may open refunds". Nothing stops activateClaims after that deadline
    /// until someone calls expireExecution, so a late launch batch pre-empts every holder's timeout exit
    /// and releases their v1 to the settlement leg.
    function test_ORACLE_migration_ActivationAfterTheExecutionDeadline() public {
        MigrationVault vault = _vault(true, 10_000);
        _deposit(vault, alice, 100 ether);
        _deposit(vault, bob, 100 ether);
        vm.warp(vault.DEPOSIT_DEADLINE() + 1);
        vault.commitRoot(_root(_leaves2(alice, 100 ether, bob, 100 ether)), 200 ether);
        v2.mint(address(vault), 200 ether);

        // The launch batch lands one second after the published execution deadline, before any holder
        // has called expireExecution.
        vm.warp(vault.rootCommittedAt() + EXECUTION_WINDOW + 1);
        (bool activated,) = address(vault).call(abi.encodeCall(MigrationVault.activateClaims, ()));
        assertFalse(activated, "activateClaims succeeded after the execution deadline: the timeout exit was pre-empted");

        vm.startPrank(relayer);
        vault.expireExecution();
        _hardened(vault).refund(alice);
        _hardened(vault).refund(bob);
        vm.stopPrank();
        assertEq(v1.balanceOf(alice), 100 ether, "alice exits through the published timeout");
        assertEq(v1.balanceOf(bob), 100 ether, "bob exits through the published timeout");
    }

    /// Oracle round 2, finding 1. claim() never checks a payout against the committed total. commitRoot can
    /// only check the total the Safe declares, not the leaves behind the root, so a malformed root whose leaves
    /// sum past totalClaimable, in a vault holding more v2 than the backing (a donation, a mistaken transfer),
    /// pays out v2 nobody was promised. Honest roots are unaffected: their leaves sum to exactly the total.
    function test_ORACLE_migration_PayoutsNeverExceedTheCommittedTotal() public {
        MigrationVault vault = _vault(false, 10_000);
        _deposit(vault, alice, 100 ether);
        vm.warp(vault.DEPOSIT_DEADLINE() + 1);
        // The declared total is alice's 100, but the root also carries a 100-token leaf for bob.
        bytes32[] memory leaves = _leaves2(alice, 100 ether, bob, 100 ether);
        vault.commitRoot(_root(leaves), 100 ether);
        v2.mint(address(vault), 200 ether); // the backing plus 100 v2 that was never promised to anyone
        vault.activateClaims();

        vm.prank(relayer);
        vault.claim(0, alice, 100 ether, _proof(leaves, 0));
        vm.prank(relayer);
        (bool paid,) = address(vault).call(abi.encodeCall(MigrationVault.claim, (1, bob, 100 ether, _proof(leaves, 1))));
        assertFalse(paid, "a leaf outside the committed total was paid");
        assertEq(vault.totalClaimedAmount(), 100 ether, "payouts stay within totalClaimable");
    }

    /// Oracle round 2, finding 2. The constructor accepts any claimPeriod, but activateClaims computes
    /// block.timestamp + CLAIM_PERIOD. A value that overflows (type(uint256).max, the vault's own internal
    /// "never" sentinel) deploys, takes deposits and commits, then panics in the launch batch: the migration
    /// can never go live and every depositor waits out the execution window for a refund.
    function test_ORACLE_migration_ClaimPeriodThatOverflowsBricksActivation() public {
        v1 = new MockERC20("v1", "V1");
        v2 = new MockERC20("v2", "V2");
        uint256 depositDeadline = block.timestamp + DEPOSIT_WINDOW;
        try new MigrationVault(
            v1,
            v2,
            depositDeadline,
            depositDeadline + COMMIT_WINDOW,
            EXECUTION_WINDOW,
            type(uint256).max,
            10_000,
            true,
            address(this)
        ) returns (
            MigrationVault vault
        ) {
            _deposit(vault, alice, 100 ether);
            vm.warp(vault.DEPOSIT_DEADLINE() + 1);
            vault.commitRoot(_root(_leaves2(alice, 100 ether, bob, 0)), 100 ether);
            v2.mint(address(vault), 100 ether);
            (bool activated,) = address(vault).call(abi.encodeCall(MigrationVault.activateClaims, ()));
            assertTrue(activated, "a vault that accepted deposits can never activate claims (claimPeriod overflow)");
        } catch {
            // Rejected at deployment, before anyone could deposit: the other acceptable fix.
        }
    }

    /// Oracle round 2, finding 2 (second half). An executionWindow large enough that
    /// rootCommittedAt + EXECUTION_WINDOW overflows makes expireExecution panic forever: after commitRoot, a
    /// Safe that never activates leaves every depositor with no timeout exit. It must be refused at deployment,
    /// with a clean error rather than an arithmetic panic, so a bad deploy config names its cause.
    function test_ORACLE_migration_ExecutionWindowThatOverflowsIsRejected() public {
        v1 = new MockERC20("v1", "V1");
        v2 = new MockERC20("v2", "V2");
        uint256 depositDeadline = block.timestamp + DEPOSIT_WINDOW;
        (bool deployed, bytes memory ret) = address(this)
            .call(
                abi.encodeCall(this.deployWithExecutionWindow, (depositDeadline, type(uint256).max - depositDeadline))
            );
        assertFalse(deployed, "a vault whose timeout exit can overflow was deployed");
        assertEq(
            keccak256(ret),
            keccak256(abi.encodeWithSelector(MigrationVault.WindowTooLong.selector)),
            "refused for the named reason, not an arithmetic panic"
        );
    }

    function deployWithExecutionWindow(uint256 depositDeadline, uint256 executionWindow) external {
        new MigrationVault(
            v1, v2, depositDeadline, depositDeadline + COMMIT_WINDOW, executionWindow, 0, 10_000, true, address(this)
        );
    }
}
