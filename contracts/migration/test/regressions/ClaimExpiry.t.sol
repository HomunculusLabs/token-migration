// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationVault} from "../../src/MigrationVault.sol";
import {ReviewFindingsBase} from "./ReviewFindingsBase.sol";

/// @dev P5: claim expiry froze unclaimed v2 and leftover v1 forever. The policy is a deploy
///      parameter: `claimPeriod == 0` means claims never expire; `claimPeriod > 0` means they expire
///      and the Safe then recovers what is left. Nothing is frozen under either.
contract ClaimExpiryTest is ReviewFindingsBase {
    function _launched(uint256 claimPeriod, uint256 backing)
        internal
        returns (MigrationVault vault, bytes32[] memory leaves)
    {
        vault = _vault(false, 10_000, claimPeriod);
        _deposit(vault, alice, 100 ether);
        _deposit(vault, bob, 100 ether);
        vm.warp(vault.DEPOSIT_DEADLINE() + 1);
        leaves = _leaves2(alice, 100 ether, bob, 100 ether);
        vault.commitRoot(_root(leaves), 200 ether);
        v2.mint(address(vault), backing);
        vault.activateClaims();
        vault.withdrawV1ForSettlement(address(this), 150 ether); // the Safe sells in chunks, 50 left
        vault.claim(0, alice, 100 ether, _proof(leaves, 0));
    }

    /// Option A (claimPeriod 0): a holder can claim years later, the Safe can still reach the
    /// leftover v1, and a sweep takes only the v2 above what is still owed.
    function test_P5_NoExpiryModeFreezesNothing() public {
        (MigrationVault vault, bytes32[] memory leaves) = _launched(0, 207 ether); // 7 over-funded

        vault.sweepResidual();
        assertEq(v2.balanceOf(address(this)), 7 ether, "only the over-funding is swept");

        vm.warp(block.timestamp + 3650 days);
        vm.expectRevert(
            abi.encodeWithSelector(MigrationVault.ClaimWindowStillOpen.selector, type(uint256).max, block.timestamp)
        );
        vault.expireClaims();
        vault.claim(1, bob, 100 ether, _proof(leaves, 1));
        assertEq(v2.balanceOf(bob), 100 ether, "bob claims ten years late");

        vault.withdrawV1ForSettlement(address(this), 50 ether);
        assertEq(v1.balanceOf(address(vault)), 0, "leftover v1 reached");
        assertEq(v2.balanceOf(address(vault)), 0, "nothing frozen");
    }

    /// Option B (claimPeriod > 0): after expiry the Safe recovers bob's unclaimed v2 and the
    /// leftover v1.
    function test_P5_ExpiryModeLetsTheSafeRecoverLeftovers() public {
        (MigrationVault vault, bytes32[] memory leaves) = _launched(CLAIM_PERIOD, 200 ether);

        vm.warp(vault.claimWindowEnd() + 1);
        vault.expireClaims();
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.claim(1, bob, 100 ether, _proof(leaves, 1));

        vault.sweepResidual();
        assertEq(v2.balanceOf(address(this)), 100 ether, "bob's unclaimed v2 goes to the Safe");
        _hardened(vault).rescueV1(address(this)); // after activation no v1 is owed to anyone in v1
        assertEq(v1.balanceOf(address(this)), 200 ether, "all 200 v1 reached the Safe");
        assertEq(v1.balanceOf(address(vault)), 0, "no v1 frozen");
        assertEq(v2.balanceOf(address(vault)), 0, "no v2 frozen");
    }

    /// Before expiry a sweep can never touch an entitlement, in either mode.
    function test_SweepNeverTakesOutstandingEntitlementsBeforeExpiry() public {
        (MigrationVault vault,) = _launched(CLAIM_PERIOD, 200 ether);
        vm.expectRevert(MigrationVault.NothingToSweep.selector);
        vault.sweepResidual();
        assertEq(v2.balanceOf(address(vault)), 100 ether, "bob's entitlement stays backed");
    }

    /// Backing posted to a vault that then times out is nobody's entitlement: it goes back to the
    /// Safe instead of being frozen.
    function test_BackingPostedBeforeATimeoutIsRecoverable() public {
        MigrationVault vault = _vault(false, 10_000, CLAIM_PERIOD);
        _deposit(vault, alice, 100 ether);
        vm.warp(vault.DEPOSIT_DEADLINE() + 1);
        vault.commitRoot(_root(_leaves2(alice, 100 ether, bob, 0)), 100 ether);
        v2.mint(address(vault), 100 ether);
        vm.warp(vault.rootCommittedAt() + EXECUTION_WINDOW + 1);
        vault.expireExecution();

        vault.sweepResidual();
        assertEq(v2.balanceOf(address(this)), 100 ether, "the unused backing returns to the Safe");
        _hardened(vault).refund(alice);
        assertEq(v1.balanceOf(alice), 100 ether, "alice refunded");
    }
}
