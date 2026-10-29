// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SurplusTokenV2} from "../src/SurplusTokenV2.sol";
import {TokenFixture} from "./TokenFixture.sol";

/**
 * @title Mint limiter (epoch throttle) behavior.
 * @dev The limiter is UNSET at deployment: the atomic launch batch mints the whole migrated supply
 *      plus the LP budget in one transaction, and must stay unconstrained by construction. The Safe
 *      engages the throttle post-launch; the epoch grid is then immutable (only the per-epoch
 *      amount is tunable). Budgets hard-reset each epoch; nothing rolls over.
 */
contract MintLimiterTest is TokenFixture {
    uint256 internal constant EPOCH = 1 days;
    uint256 internal constant LIMIT = 10_000 ether;

    function setUp() public override {
        super.setUp();
    }

    /// @dev L-0 (the launch constraint, the reason the limiter ships disengaged): while unset,
    ///      a launch-shaped mint — backing + LP budget in ONE transaction, well past any sane
    ///      epoch budget — succeeds. A naive always-on limiter would brick the atomic launch.
    function test_L0_LaunchBatchMintUnconstrainedWhileUnset() public {
        assertTrue(token.mintRemainingThisEpoch() == token.NO_MINT_LIMIT(), "limiter must ship unset");
        _launchMints(PLACEHOLDER_BACKING, PLACEHOLDER_LP_BUDGET); // 850k of a 1M cap, one tx each
        assertTrue(token.totalSupply() == PLACEHOLDER_BACKING + PLACEHOLDER_LP_BUDGET, "launch mints");
    }

    /// @dev L-1: engaging the limit is admin-only; a stranger (even the minter-role holder's
    ///      neighbor, an EOA) cannot engage, tune or lift it.
    function test_L1_SetMintLimitIsAdminOnly() public {
        vm.prank(stranger);
        vm.expectRevert(_missingRole(stranger, 0x00));
        token.setMintLimit(LIMIT, EPOCH);
    }

    /// @dev L-2: first engage fixes the epoch grid; a later call may not change the length.
    function test_L2_EpochGridIsImmutableAfterFirstEngage() public {
        _engage(LIMIT, EPOCH);
        _safeBatchReverts(
            _single(abi.encodeCall(SurplusTokenV2.setMintLimit, (LIMIT, 2 days))),
            abi.encodeWithSelector(SurplusTokenV2.EpochGridFixed.selector, EPOCH, 2 days)
        );
        // Same length, different amount: allowed.
        _engage(LIMIT * 2, EPOCH);
    }

    /// @dev L-3: zero epoch length is rejected on engage.
    function test_L3_ZeroEpochRejected() public {
        _safeBatchReverts(
            _single(abi.encodeCall(SurplusTokenV2.setMintLimit, (LIMIT, 0))),
            abi.encodeWithSelector(SurplusTokenV2.ZeroEpoch.selector)
        );
    }

    /// @dev L-4: the happy path — mint up to the limit, over-limit reverts with the remaining
    ///      budget, the NEXT epoch opens a fresh budget (hard reset, no roll-over).
    function test_L4_LimitBindsAndHardResetsNextEpoch() public {
        _engage(LIMIT, EPOCH);
        _safeMint(vault, LIMIT - 1 ether);
        assertTrue(token.mintRemainingThisEpoch() == 1 ether, "remaining after LIMIT-1");

        vm.prank(address(safe));
        vm.expectRevert(abi.encodeWithSelector(SurplusTokenV2.MintLimitExceeded.selector, 2 ether, 1 ether));
        token.mint(vault, 2 ether);

        _safeMint(vault, 1 ether); // exactly the remaining budget
        assertTrue(token.mintRemainingThisEpoch() == 0, "epoch exhausted");

        vm.warp(block.timestamp + EPOCH + 1);
        assertTrue(token.mintRemainingThisEpoch() == LIMIT, "fresh epoch budget");
        _safeMint(vault, LIMIT); // full budget again
    }

    /// @dev L-5: unused allowance does NOT roll over — skip an epoch, still only LIMIT.
    function test_L5_NoRolloverOfUnusedBudget() public {
        _engage(LIMIT, EPOCH);
        _safeMint(vault, LIMIT / 10);
        vm.warp(block.timestamp + 3 * EPOCH + 1); // skip two full epochs
        assertTrue(token.mintRemainingThisEpoch() == LIMIT, "no accrual");
        vm.prank(address(safe));
        vm.expectRevert(abi.encodeWithSelector(SurplusTokenV2.MintLimitExceeded.selector, LIMIT + 1, LIMIT));
        token.mint(vault, LIMIT + 1);
        _safeMint(vault, LIMIT);
    }

    /// @dev L-6: the Safe may LOWER the limit below what this epoch already minted — the
    ///      remaining budget reads zero and mints revert until the next epoch (no underflow).
    function test_L6_LoweringBelowSpentZeroesRemainderNoUnderflow() public {
        _engage(LIMIT, EPOCH);
        _safeMint(vault, LIMIT);
        _engage(LIMIT / 2, EPOCH); // lower below the spent amount, same grid
        assertTrue(token.mintRemainingThisEpoch() == 0, "spent >= limit reads zero");
        vm.prank(address(safe));
        vm.expectRevert(abi.encodeWithSelector(SurplusTokenV2.MintLimitExceeded.selector, 1, 0));
        token.mint(vault, 1);
        vm.warp(block.timestamp + EPOCH + 1);
        _safeMint(vault, LIMIT / 2); // fresh epoch, new limit applies
    }

    /// @dev L-7: lifting the limit (NO_MINT_LIMIT) restores unconstrained minting on the same grid.
    function test_L7_LiftRestoresUnconstrainedMinting() public {
        _engage(LIMIT, EPOCH);
        _safeMint(vault, LIMIT);
        _engage(0, EPOCH); // 0 lifts the limit (same grid)
        assertTrue(token.mintRemainingThisEpoch() == token.NO_MINT_LIMIT(), "lifted");
        _safeMint(vault, 100_000 ether); // way past the old limit
        _engage(LIMIT, EPOCH); // and can be re-engaged afterwards
        vm.prank(address(safe));
        vm.expectRevert(abi.encodeWithSelector(SurplusTokenV2.MintLimitExceeded.selector, 1, 0));
        token.mint(vault, 1);
    }

    /// @dev L-8: epoch boundary arithmetic — mints land in the correct epoch across the seam,
    ///      including several epochs ahead (anchor advancement keeps the grid).
    function test_L8_EpochSeamAndAnchorAdvancement() public {
        _engage(LIMIT, EPOCH);
        _safeMint(vault, LIMIT);
        vm.warp(block.timestamp + 5 * EPOCH + 1); // five epochs ahead
        _safeMint(vault, LIMIT / 2);
        assertTrue(token.mintRemainingThisEpoch() == LIMIT / 2, "half spent in the new epoch");
        vm.warp(block.timestamp + EPOCH); // into the next epoch again
        assertTrue(token.mintRemainingThisEpoch() == LIMIT, "anchor advanced with the grid");
    }

    /// @dev L-9: engagement itself does not constrain mints already made — nothing retroactive —
    ///      and minting while unset never tracks (engagement opens a fresh budget).
    function test_L9_EngagementIsNotRetroactive() public {
        _safeMint(vault, 500_000 ether); // unconstrained, untracked
        _engage(LIMIT, EPOCH);
        assertTrue(token.mintRemainingThisEpoch() == LIMIT, "fresh budget at engagement");
        _safeMint(vault, LIMIT);
    }

    // ----------------------------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------------------------

    function _engage(uint256 limit, uint256 epoch) internal {
        _safeBatch(_single(abi.encodeCall(SurplusTokenV2.setMintLimit, (limit, epoch))));
    }

    function _safeMint(address to, uint256 amount) internal {
        _safeBatch(_single(abi.encodeCall(SurplusTokenV2.mint, (to, amount))));
    }
}
