// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationVault} from "../src/MigrationVault.sol";
import {MockERC20} from "./MockERC20.sol";
import {TestMerkle} from "./TestMerkle.sol";
import {Test} from "./Base.t.sol";

/**
 * @dev Full behavior suite for the migration vault. Organized by the phase machine because that IS
 *      the contract's contract: who can do what, when, and what can never happen in between.
 *
 *      Conventions: `alice`/`bob` are holders, `owner` is the operator (the SUR-662 Safe in
 *      production), `relayer` is a third party submitting proofs for others.
 */
contract MigrationVaultTest is Test {
    MockERC20 internal v1;
    MockERC20 internal v2;
    MigrationVault internal vault;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal relayer = makeAddr("relayer");

    uint256 internal constant DEPOSIT_DEADLINE = 2_000_000;
    uint256 internal constant COMMIT_DEADLINE = DEPOSIT_DEADLINE + 3 days;
    uint256 internal constant EXECUTION_WINDOW = 7 days;
    uint256 internal constant CLAIM_PERIOD = 180 days;
    /// @dev 1:1 — the draft allocation ratio. The setUp vault keeps the proofless path DISABLED so
    ///      the root-only behavior under test is exactly the pre-composite contract's.
    uint256 internal constant RATE_BPS = 10_000;

    function setUp() public {
        v1 = new MockERC20("Surplus v1", "SURPLUS");
        v2 = new MockERC20("Surplus v2", "SURPLUS2");
        vault = new MigrationVault(
            v1, v2, DEPOSIT_DEADLINE, COMMIT_DEADLINE, EXECUTION_WINDOW, CLAIM_PERIOD, RATE_BPS, false, address(this)
        );

        v1.mint(alice, 1_000_000e18);
        v1.mint(bob, 500_000e18);
        v2.mint(address(this), 10_000_000e18);
    }

    // -----------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------

    function makeAddr(string memory label) internal returns (address a) {
        a = vm.addr(uint256(keccak256(abi.encodePacked(label))));
        vm.label(a, label);
    }

    function _deposit(address who, uint256 amount) internal {
        vm.startPrank(who);
        v1.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function _commitSimpleRoot() internal returns (bytes32[] memory leaves, uint256 total) {
        // Two allocations: alice 600k, bob 500k (net of her ledger withdrawal).
        leaves = new bytes32[](2);
        leaves[0] = TestMerkle.leaf(0, alice, 600_000e18);
        leaves[1] = TestMerkle.leaf(1, bob, 500_000e18);
        total = 600_000e18 + 500_000e18;
        vault.commitRoot(TestMerkle.rootOf(_copy(leaves)), total);
    }

    function _activateClaims(uint256 backing) internal {
        v2.checkedTransfer(address(vault), backing);
        vault.activateClaims();
    }

    function _proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory) {
        return TestMerkle.proofFor(_copy(leaves), index);
    }

    function _copy(bytes32[] memory src) internal pure returns (bytes32[] memory dst) {
        dst = new bytes32[](src.length);
        for (uint256 i; i < src.length; ++i) {
            dst[i] = src[i];
        }
    }

    /// @dev Swap in a vault with the proofless path enabled at `rateBps`. The setUp vault stays
    ///      root-only; pro-rata tests opt in explicitly so the two configurations never blur.
    function _newProRataVault(uint256 rateBps) internal {
        vault = new MigrationVault(
            v1, v2, DEPOSIT_DEADLINE, COMMIT_DEADLINE, EXECUTION_WINDOW, CLAIM_PERIOD, rateBps, true, address(this)
        );
    }

    // -----------------------------------------------------------------------------------------
    // Deployment
    // -----------------------------------------------------------------------------------------

    function test_DeploymentConfigIsImmutable() public view {
        assertEq(address(vault.V1()), address(v1), "V1");
        assertEq(address(vault.V2()), address(v2), "V2");
        assertEq(vault.DEPOSIT_DEADLINE(), DEPOSIT_DEADLINE, "deadline");
        assertEq(vault.COMMIT_DEADLINE(), COMMIT_DEADLINE, "commit deadline");
        assertEq(vault.EXECUTION_WINDOW(), EXECUTION_WINDOW, "execution window");
        assertEq(vault.CLAIM_PERIOD(), CLAIM_PERIOD, "claim period");
        assertEq(vault.MIGRATION_RATE_BPS(), RATE_BPS, "rate");
        assertFalse(vault.PRO_RATA_ENABLED(), "pro-rata disabled in setUp");
        assertEq(uint8(vault.phase()), uint8(MigrationVault.Phase.Open), "starts Open");
    }

    function test_RevertIf_DepositDeadlineNotInFuture() public {
        vm.expectRevert(
            abi.encodeWithSelector(MigrationVault.DeadlineTooSoon.selector, block.timestamp, block.timestamp)
        );
        new MigrationVault(
            v1, v2, block.timestamp, COMMIT_DEADLINE, EXECUTION_WINDOW, CLAIM_PERIOD, RATE_BPS, false, address(this)
        );
    }

    function test_RevertIf_CommitDeadlineNotAfterDepositDeadline() public {
        vm.expectRevert(
            abi.encodeWithSelector(MigrationVault.InvalidCommitDeadline.selector, DEPOSIT_DEADLINE, DEPOSIT_DEADLINE)
        );
        new MigrationVault(
            v1, v2, DEPOSIT_DEADLINE, DEPOSIT_DEADLINE, EXECUTION_WINDOW, CLAIM_PERIOD, RATE_BPS, false, address(this)
        );
    }

    function test_RevertIf_ZeroTokenOrOwner() public {
        vm.expectRevert(MigrationVault.ZeroAddress.selector);
        new MigrationVault(
            MockERC20(address(0)),
            v2,
            DEPOSIT_DEADLINE,
            COMMIT_DEADLINE,
            EXECUTION_WINDOW,
            CLAIM_PERIOD,
            RATE_BPS,
            false,
            address(this)
        );
        vm.expectRevert(MigrationVault.ZeroAmount.selector);
        new MigrationVault(v1, v2, DEPOSIT_DEADLINE, COMMIT_DEADLINE, 0, CLAIM_PERIOD, RATE_BPS, false, address(this));
    }

    // -----------------------------------------------------------------------------------------
    // Open phase: deposits
    // -----------------------------------------------------------------------------------------

    function test_DepositCreditsSender() public {
        _deposit(alice, 100e18);
        assertEq(vault.credited(alice), 100e18, "credit");
        assertEq(v1.balanceOf(address(vault)), 100e18, "custody");
        assertEq(vault.totalDepositedV1(), 100e18, "total");
    }

    function test_RepeatedDepositsAggregate() public {
        _deposit(alice, 100e18);
        _deposit(alice, 33e18);
        assertEq(vault.credited(alice), 133e18, "aggregated");
    }

    function test_RevertIf_DepositZero() public {
        vm.prank(alice);
        vm.expectRevert(MigrationVault.ZeroAmount.selector);
        vault.deposit(0);
    }

    function test_RevertIf_DepositAfterDeadline() public {
        vm.warp(DEPOSIT_DEADLINE + 1);
        vm.prank(alice);
        v1.approve(address(vault), 1e18);
        vm.expectRevert(MigrationVault.DepositWindowClosed.selector);
        vault.deposit(1e18);
    }

    function test_RevertIf_DepositAfterCommitOrCancel() public {
        vm.warp(DEPOSIT_DEADLINE + 1);
        vault.commitRoot(bytes32(uint256(1)), 1e18);
        vm.prank(alice);
        v1.approve(address(vault), 1e18);
        vm.expectRevert(MigrationVault.NotOpen.selector);
        vault.deposit(1e18);
    }

    // -----------------------------------------------------------------------------------------
    // Open phase: ledger withdrawals
    // -----------------------------------------------------------------------------------------

    function test_WithdrawMyDepositWhileOpen() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.withdrawV1(40e18);
        assertEq(vault.credited(alice), 100e18, "credit unchanged (gross)");
        assertEq(v1.balanceOf(alice), 999_900e18 + 40e18, "v1 returned");
        assertEq(vault.availableToWithdraw(alice), 60e18, "available net");
    }

    function test_RevertIf_WithdrawMoreThanCredited() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.ExcessiveWithdrawal.selector, 101e18, 100e18));
        vault.withdrawV1(101e18);
    }

    function test_RevertIf_WithdrawAfterRootCommitted() public {
        _deposit(alice, 100e18);
        vm.warp(DEPOSIT_DEADLINE + 1);
        vault.commitRoot(bytes32(uint256(1)), 100e18);
        vm.prank(alice);
        vm.expectRevert(MigrationVault.LedgerWithdrawalsFrozen.selector);
        vault.withdrawV1(1e18);
    }

    function test_WithdrawAgainAfterCancel() public {
        _deposit(alice, 100e18);
        vault.cancel();
        vm.prank(alice);
        vault.withdrawV1(100e18);
        assertEq(v1.balanceOf(alice), 1_000_000e18, "full recovery after cancel");
    }

    // -----------------------------------------------------------------------------------------
    // Root commitment — the point of no return
    // -----------------------------------------------------------------------------------------

    function test_CommitRootFreezesLedgerAndMovesPhase() public {
        _deposit(alice, 100e18);
        vm.warp(DEPOSIT_DEADLINE + 1);
        bytes32 r = bytes32(uint256(0xC0FFEE));
        vault.commitRoot(r, 100e18);
        assertEq(uint8(vault.phase()), uint8(MigrationVault.Phase.Committed), "phase");
        assertEq(vault.root(), r, "root");
        assertEq(vault.totalClaimable(), 100e18, "total");
        assertEq(vault.rootCommittedAt(), block.timestamp, "committedAt");
    }

    function test_RevertIf_CommitBeforeDeadline() public {
        _deposit(alice, 100e18);
        vm.expectRevert(
            abi.encodeWithSelector(MigrationVault.DeadlineNotPassed.selector, DEPOSIT_DEADLINE, block.timestamp)
        );
        vault.commitRoot(bytes32(uint256(1)), 100e18);
    }

    function test_RevertIf_CommitByNonOwner() public {
        vm.warp(DEPOSIT_DEADLINE + 1);
        vm.prank(alice);
        vm.expectRevert(MigrationVault.NotOwner.selector);
        vault.commitRoot(bytes32(uint256(1)), 1e18);
    }

    // -----------------------------------------------------------------------------------------
    // Activation — the fully-backed gate
    // -----------------------------------------------------------------------------------------

    function test_RevertIf_ActivateUnderfunded() public {
        vm.warp(DEPOSIT_DEADLINE + 1);
        vault.commitRoot(bytes32(uint256(1)), 100e18);
        v2.checkedTransfer(address(vault), 99e18);
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.InsufficientBacking.selector, 100e18, 99e18));
        vault.activateClaims();
    }

    function test_ActivateRecordsWindow() public {
        vm.warp(DEPOSIT_DEADLINE + 1);
        vault.commitRoot(bytes32(uint256(1)), 100e18);
        v2.checkedTransfer(address(vault), 100e18);
        vault.activateClaims();
        assertTrue(vault.claimsActive(), "active");
        assertEq(vault.claimWindowEnd(), block.timestamp + CLAIM_PERIOD, "window end");
    }

    // -----------------------------------------------------------------------------------------
    // The ordering rule: v1 for settlement ONLY after claims are live
    // -----------------------------------------------------------------------------------------

    function test_RevertIf_SettlementWithdrawalBeforeActivation() public {
        vm.warp(DEPOSIT_DEADLINE + 1);
        vault.commitRoot(bytes32(uint256(1)), 100e18);
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.withdrawV1ForSettlement(address(this), 1e18);
    }

    // -----------------------------------------------------------------------------------------
    // Claims
    // -----------------------------------------------------------------------------------------

    function test_ClaimPaysLeafBeneficiaryNotCaller() public {
        (bytes32[] memory leaves,) = _depositAndCommitAndActivate();

        uint256 before = v2.balanceOf(alice);
        vm.prank(relayer); // NOT alice — the relayer cannot redirect the payout
        vault.claim(0, alice, 600_000e18, _proof(leaves, 0));
        assertEq(v2.balanceOf(alice), before + 600_000e18, "beneficiary paid");
        assertEq(v2.balanceOf(relayer), 0, "relayer got nothing");
        assertTrue(vault.isClaimed(0), "bitmap set");
    }

    function test_ClaimByBeneficiaryThemself() public {
        (bytes32[] memory leaves,) = _depositAndCommitAndActivate();
        vm.prank(bob);
        vault.claim(1, bob, 500_000e18, _proof(leaves, 1));
        assertEq(v2.balanceOf(bob), 500_000e18, "bob paid");
    }

    function test_RevertIf_ClaimBeforeActivation() public {
        _deposit(alice, 100e18);
        vm.warp(DEPOSIT_DEADLINE + 1);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = TestMerkle.leaf(0, alice, 100e18);
        vault.commitRoot(TestMerkle.rootOf(leaves), 100e18);
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.claim(0, alice, 100e18, leaves); // wrong proof too; revert order: claims gate first
    }

    function test_RevertIf_ClaimTwice() public {
        (bytes32[] memory leaves,) = _depositAndCommitAndActivate();
        vault.claim(0, alice, 600_000e18, _proof(leaves, 0));
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.AlreadyClaimed.selector, 0));
        vault.claim(0, alice, 600_000e18, _proof(leaves, 0));
    }

    /// @dev An already-claimed nonzero index must reject a second claim, even if its amount changes.
    function test_RevertIf_ClaimTwice_HighIndex() public {
        (bytes32[] memory leaves,) = _depositAndCommitAndActivate();
        vault.claim(1, bob, 500_000e18, _proof(leaves, 1)); // Exercise a nonzero bitmap bit.
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.AlreadyClaimed.selector, 1));
        vault.claim(1, bob, 500_000e28, _proof(leaves, 1)); // different amount, same index
    }

    function test_RevertIf_InvalidProof() public {
        (bytes32[] memory leaves,) = _depositAndCommitAndActivate();
        vm.expectRevert(MigrationVault.InvalidProof.selector);
        vault.claim(0, alice, 599_000e18, _proof(leaves, 0)); // amount not in tree
    }

    function test_RevertIf_ClaimWrongBeneficiary() public {
        (bytes32[] memory leaves,) = _depositAndCommitAndActivate();
        vm.expectRevert(MigrationVault.InvalidProof.selector);
        vault.claim(0, relayer, 600_000e18, _proof(leaves, 0)); // beneficiary not in tree
    }

    function test_RevertIf_ClaimAfterWindowEnds() public {
        (bytes32[] memory leaves,) = _depositAndCommitAndActivate();
        vm.warp(vault.claimWindowEnd() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(MigrationVault.ClaimWindowEnded.selector, vault.claimWindowEnd(), block.timestamp)
        );
        vault.claim(0, alice, 600_000e18, _proof(leaves, 0));
    }

    function test_ManyHoldersAllClaim() public {
        // 65 holders (past the documented top-holder concentration scale) — exercises multi-word bitmap.
        uint256 n = 65;
        _deposit(alice, 1_000_000e18);
        _deposit(bob, 500_000e18);
        vm.warp(DEPOSIT_DEADLINE + 1);

        bytes32[] memory leaves = new bytes32[](n);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            address who = vm.addr(uint256(keccak256(abi.encodePacked("holder", i))));
            uint256 amt = 1_000e18 * (i + 1);
            leaves[i] = TestMerkle.leaf(i, who, amt);
            total += amt;
        }
        vault.commitRoot(TestMerkle.rootOf(_copy(leaves)), total);
        v2.checkedTransfer(address(vault), total);
        vault.activateClaims();

        for (uint256 i; i < n; ++i) {
            address who = vm.addr(uint256(keccak256(abi.encodePacked("holder", i))));
            vault.claim(i, who, 1_000e18 * (i + 1), _proof(leaves, i));
            assertEq(v2.balanceOf(who), 1_000e18 * (i + 1), "paid");
        }
        assertEq(vault.totalClaimedAmount(), total, "total");
    }

    // -----------------------------------------------------------------------------------------
    // Execution timeout — the enforced refund right
    // -----------------------------------------------------------------------------------------

    function test_ExpireExecutionOpensLedgerRefunds() public {
        _depositAndCommit();
        vm.warp(vault.rootCommittedAt() + EXECUTION_WINDOW + 1);
        vault.expireExecution(); // anyone
        assertEq(uint8(vault.phase()), uint8(MigrationVault.Phase.Cancelled), "phase");

        uint256 before = v1.balanceOf(alice);
        vm.prank(relayer);
        vault.refund(alice);
        assertEq(v1.balanceOf(alice), before + 600_000e18, "v1 refunded");
    }

    function test_RevertIf_ExpireBeforeWindowEnds() public {
        _depositAndCommit();
        vm.warp(vault.rootCommittedAt() + EXECUTION_WINDOW - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                MigrationVault.ExecutionWindowStillOpen.selector,
                vault.rootCommittedAt() + EXECUTION_WINDOW,
                block.timestamp
            )
        );
        vault.expireExecution();
    }

    function test_TimeoutRefundsAreBackedByConstruction() public {
        // After expiry, Σ leaf refunds must not exceed the v1 actually in the vault — because v1
        // cannot have left (settlement withdrawal requires active claims, which never happened).
        (, uint256 total) = _depositAndCommit();
        vm.warp(vault.rootCommittedAt() + EXECUTION_WINDOW + 1);
        vault.expireExecution();
        assertGe(v1.balanceOf(address(vault)), total, "vault backs every refund");
        // ...and both depositors can actually be paid
        vault.refund(alice);
        vault.refund(bob);
        assertEq(v1.balanceOf(address(vault)), 0, "every deposit returned");
        assertEq(vault.totalClaimable(), total, "total recorded");
    }

    function test_RevertIf_RefundWhileCommitted() public {
        _depositAndCommit();
        vm.expectRevert(MigrationVault.NotRefundPhase.selector);
        vault.refund(alice);
    }

    function test_RevertIf_RefundTwice() public {
        _depositAndCommit();
        vm.warp(vault.rootCommittedAt() + EXECUTION_WINDOW + 1);
        vault.expireExecution();
        vault.refund(alice);
        vm.expectRevert(MigrationVault.NothingToWithdraw.selector);
        vault.refund(alice);
    }

    // -----------------------------------------------------------------------------------------
    // Settlement + residual
    // -----------------------------------------------------------------------------------------

    function test_SettlementWithdrawalOnlyAfterActivation() public {
        (, uint256 total) = _depositAndCommitAndActivate();
        uint256 before = v1.balanceOf(address(this));
        vault.withdrawV1ForSettlement(address(this), total);
        assertEq(v1.balanceOf(address(this)), before + total, "v1 out for sale");
    }

    function test_ExpiredClaimWindowSweepsTheUnclaimedToTheOwner() public {
        // setUp deploys with a positive CLAIM_PERIOD, i.e. expiring claims (DESIGN.md §11 P5):
        // once the window closes nobody can claim, and the unclaimed remainder goes to the owner
        // instead of staying frozen in the vault.
        (, uint256 total) = _depositAndCommitAndActivate();
        vm.warp(vault.claimWindowEnd() + 1);
        vault.expireClaims();

        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.claim(0, alice, 600_000e18, _proof(new bytes32[](2), 0));

        uint256 before = v2.balanceOf(address(this));
        vault.sweepResidual();
        assertEq(v2.balanceOf(address(this)), before + total, "unclaimed remainder swept to the owner");
        assertEq(v2.balanceOf(address(vault)), 0, "nothing frozen");
    }

    function test_SweepPaysResidualToOwner() public {
        (bytes32[] memory leaves,) = _depositAndCommitAndActivate();
        // claim everything while the window is open
        vault.claim(0, alice, 600_000e18, _proof(leaves, 0));
        vault.claim(1, bob, 500_000e18, _proof(leaves, 1));
        // over-fund by 7 wei of dust
        v2.checkedTransfer(address(vault), 7);
        vm.warp(vault.claimWindowEnd() + 1);
        vault.expireClaims();

        uint256 before = v2.balanceOf(address(this));
        vault.sweepResidual();
        assertEq(v2.balanceOf(address(this)), before + 7, "residual swept");
    }

    function test_SweepWhileWindowOpenTakesOnlyTheExcess() public {
        (, uint256 total) = _depositAndCommitAndActivate();
        vm.expectRevert(MigrationVault.NothingToSweep.selector); // exactly backed: no excess
        vault.sweepResidual();

        v2.checkedTransfer(address(vault), 5);
        uint256 before = v2.balanceOf(address(this));
        vault.sweepResidual();
        assertEq(v2.balanceOf(address(this)), before + 5, "only the over-funding leaves");
        assertEq(v2.balanceOf(address(vault)), total, "every open entitlement stays backed");
    }

    // -----------------------------------------------------------------------------------------
    // Ownership
    // -----------------------------------------------------------------------------------------

    function test_TwoStepOwnershipTransfer() public {
        vault.transferOwnership(alice);
        assertEq(vault.owner(), address(this), "not yet");
        vm.prank(alice);
        vault.acceptOwnership();
        assertEq(vault.owner(), alice, "transferred");
    }

    function test_RevertIf_AcceptByWrongParty() public {
        vault.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(MigrationVault.NotOwner.selector);
        vault.acceptOwnership();
    }

    function test_RevertIf_OwnerFunctionsByOutsider() public {
        vm.prank(alice);
        vm.expectRevert(MigrationVault.NotOwner.selector);
        vault.cancel();
    }

    // -----------------------------------------------------------------------------------------
    // Compound scenario: the whole happy path
    // -----------------------------------------------------------------------------------------

    function test_FullLifecycle() public {
        _deposit(alice, 600_000e18);
        _deposit(bob, 500_000e18);

        vm.warp(DEPOSIT_DEADLINE + 1);
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = TestMerkle.leaf(0, alice, 600_000e18);
        leaves[1] = TestMerkle.leaf(1, bob, 500_000e18);
        vault.commitRoot(TestMerkle.rootOf(_copy(leaves)), 1_100_000e18);

        v2.checkedTransfer(address(vault), 1_100_000e18);
        vault.activateClaims();

        // settlement leg runs AFTER backing is posted
        vault.withdrawV1ForSettlement(address(this), 1_100_000e18);

        vm.prank(relayer);
        vault.claim(0, alice, 600_000e18, _proof(leaves, 0));
        vault.claim(1, bob, 500_000e18, _proof(leaves, 1));

        assertEq(v2.balanceOf(alice), 600_000e18, "alice v2");
        assertEq(v2.balanceOf(bob), 500_000e18, "bob v2");
        assertEq(v1.balanceOf(address(this)), 1_100_000e18, "operator holds sold v1");
        assertEq(vault.totalClaimedAmount(), 1_100_000e18, "fully claimed");
    }

    // -----------------------------------------------------------------------------------------
    // Proofless flat-ratio claims
    // -----------------------------------------------------------------------------------------

    function test_ProRataPaysFormulaWithoutProof() public {
        _newProRataVault(RATE_BPS);
        (, uint256 total) = _depositAndCommitAndActivate(); // total = 1_100_000e18 = net ledger × 1

        vm.prank(alice);
        vault.claimProRata(); // no index, no proof, no website
        assertEq(v2.balanceOf(alice), 600_000e18, "alice formula payout");
        vm.prank(bob);
        vault.claimProRata();
        assertEq(v2.balanceOf(bob), 500_000e18, "bob formula payout");

        // Formula payouts compose with the all-claimed sweep gate: both paths feed the same total.
        assertEq(vault.totalClaimedAmount(), total, "sweep-gate total composes");
    }

    function test_ProRataRateDiscount() public {
        _newProRataVault(5_000); // 50%
        _depositAndCommitAndActivateAt(5_000);

        vm.prank(alice);
        vault.claimProRata();
        assertEq(v2.balanceOf(alice), 300_000e18, "half of credit");
    }

    function test_ProRataRoundsDownPerAccount() public {
        _newProRataVault(5_000); // 50%: 3 wei of credit must pay floor(1.5) = 1 wei, never round up
        vm.startPrank(alice);
        v1.approve(address(vault), 3);
        vault.deposit(3);
        vm.stopPrank();
        vm.warp(DEPOSIT_DEADLINE + 1);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = TestMerkle.leaf(0, alice, 1); // the tree builds the same floor
        vault.commitRoot(TestMerkle.rootOf(_copy(leaves)), 1);
        _activateClaims(1);

        vm.prank(alice);
        vault.claimProRata();
        assertEq(v2.balanceOf(alice), 1, "floored payout");
    }

    function test_ProRataNetOfWithdrawals() public {
        // Withdrawn amounts are no longer claimable, even though gross credit is unchanged.
        _newProRataVault(RATE_BPS);
        _deposit(alice, 600_000e18);
        vm.prank(alice);
        vault.withdrawV1(100_000e18);
        _deposit(bob, 500_000e18);
        vm.warp(DEPOSIT_DEADLINE + 1);
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = TestMerkle.leaf(0, alice, 500_000e18);
        leaves[1] = TestMerkle.leaf(1, bob, 500_000e18);
        vault.commitRoot(TestMerkle.rootOf(_copy(leaves)), 1_000_000e18); // net 1M × 1
        _activateClaims(1_000_000e18);

        vm.prank(alice);
        vault.claimProRata();
        assertEq(v2.balanceOf(alice), 500_000e18, "net, not gross");
        assertEq(vault.credited(alice), 600_000e18, "gross credit unchanged");
    }

    function test_RevertIf_ProRataClaimWhenDisabled() public {
        // The root-only vault must reject the disabled formula path.
        _depositAndCommitAndActivate();
        vm.prank(alice);
        vm.expectRevert(MigrationVault.ProRataDisabled.selector);
        vault.claimProRata();
    }

    function test_RevertIf_ProRataBeforeActivation() public {
        _newProRataVault(RATE_BPS);
        _depositAndCommit(); // committed, no backing posted
        vm.prank(alice);
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.claimProRata();
    }

    function test_RevertIf_ProRataAfterWindowEnd() public {
        _newProRataVault(RATE_BPS);
        _depositAndCommitAndActivate();
        vm.warp(vault.claimWindowEnd() + 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(MigrationVault.ClaimWindowEnded.selector, vault.claimWindowEnd(), block.timestamp)
        );
        vault.claimProRata();
    }

    function test_RevertIf_ProRataTwice() public {
        _newProRataVault(RATE_BPS);
        _depositAndCommitAndActivate();
        vm.startPrank(alice);
        vault.claimProRata();
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.AlreadyClaimedAccount.selector, alice));
        vault.claimProRata();
        vm.stopPrank();
    }

    function test_RevertIf_RootClaimThenProRata() public {
        _newProRataVault(RATE_BPS);
        (bytes32[] memory leaves,) = _depositAndCommitAndActivate();

        vm.prank(relayer);
        vault.claim(0, alice, 600_000e18, _proof(leaves, 0)); // root path pays alice
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.AlreadyClaimedAccount.selector, alice));
        vault.claimProRata();
    }

    function test_RevertIf_ProRataThenRootClaim() public {
        _newProRataVault(RATE_BPS);
        (bytes32[] memory leaves,) = _depositAndCommitAndActivate();

        vm.prank(alice);
        vault.claimProRata();
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.AlreadyClaimedAccount.selector, alice));
        vault.claim(0, alice, 600_000e18, _proof(leaves, 0)); // index is fresh; the account is not
    }

    function test_RevertIf_ProRataThenTimeoutRefund() public {
        // Activation permanently closes refunds, including after a formula payout and the
        // execution deadline: expireExecution must not reopen v1 withdrawals alongside v2 claims.
        _newProRataVault(RATE_BPS);
        _depositAndCommitAndActivate();
        vm.prank(alice);
        vault.claimProRata();

        vm.warp(vault.rootCommittedAt() + EXECUTION_WINDOW + 1);
        vm.expectRevert(MigrationVault.ClaimsAlreadyActive.selector);
        vault.expireExecution();
        // ...and therefore no refund path exists: phase is still Committed.
        vm.expectRevert(MigrationVault.NotRefundPhase.selector);
        vault.refund(alice);
    }

    function test_RevertIf_CommitTotalOffFormula() public {
        // The enabling precondition is enforced at commitment: with PRO_RATA_ENABLED the committed
        // total must equal the formula over the NET ledger (1.1M here), or the root cannot commit.
        _newProRataVault(RATE_BPS);
        _deposit(alice, 600_000e18);
        _deposit(bob, 500_000e18);
        vm.warp(DEPOSIT_DEADLINE + 1);
        vm.expectRevert(
            abi.encodeWithSelector(MigrationVault.ProRataTotalMismatch.selector, 1_100_000e18, 1_000_000e18)
        );
        vault.commitRoot(bytes32(uint256(1)), 1_000_000e18);
    }

    function test_RevertIf_ProRataWithNoCredit() public {
        _newProRataVault(RATE_BPS);
        _depositAndCommitAndActivate();
        vm.prank(relayer); // never deposited
        vm.expectRevert(MigrationVault.NothingToClaim.selector);
        vault.claimProRata();
    }

    function test_RevertIf_ProRataEnabledWithZeroRate() public {
        vm.expectRevert(MigrationVault.ZeroAmount.selector);
        new MigrationVault(
            v1, v2, DEPOSIT_DEADLINE, COMMIT_DEADLINE, EXECUTION_WINDOW, CLAIM_PERIOD, 0, true, address(this)
        );
    }

    // -----------------------------------------------------------------------------------------
    // Settlement verification view
    // -----------------------------------------------------------------------------------------

    function test_VerifySettlementTracksPhases() public {
        // Fresh deployment: nothing to verify.
        (bool funded, uint256 v2Bal, uint256 total, uint256 v1Held, bool active, uint256 claimed) =
            vault.verifySettlement();
        assertFalse(funded, "nothing committed");
        assertEq(v2Bal, 0, "v2");
        assertEq(total, 0, "claimable");
        assertEq(v1Held, 0, "v1");
        assertFalse(active, "inactive");
        assertEq(claimed, 0, "claimed");

        // Committed, backing not yet posted: funded must be false.
        (bytes32[] memory leaves,) = _depositAndCommit();
        v2.checkedTransfer(address(vault), 100e18); // partial backing, no activation
        (funded, v2Bal, total, v1Held, active, claimed) = vault.verifySettlement();
        assertFalse(funded, "underfunded");
        assertEq(v2Bal, 100e18, "partial backing visible");
        assertEq(total, 1_100_000e18, "claimable total");
        assertEq(v1Held, 1_100_000e18, "v1 custody");
        assertFalse(active, "not active yet");
        assertEq(claimed, 0, "claimed");

        // Activated at full backing.
        v2.checkedTransfer(address(vault), 1_100_000e18 - 100e18);
        vault.activateClaims();
        (funded, v2Bal, total, v1Held, active, claimed) = vault.verifySettlement();
        assertTrue(funded, "fully funded");
        assertEq(v2Bal, 1_100_000e18, "backing");
        assertEq(v1Held, 1_100_000e18, "v1 still in custody");
        assertTrue(active, "active");

        // Mid-window after a root claim: the flag counts paid claims, not just the raw balance.
        vault.claim(0, alice, 600_000e18, _proof(leaves, 0));
        (funded, v2Bal, total, v1Held, active, claimed) = vault.verifySettlement();
        assertTrue(funded, "500k balance + 600k paid covers 1.1M");
        assertEq(v2Bal, 500_000e18, "balance after claim");
        assertEq(claimed, 600_000e18, "claimed so far");

        // Window closed: activity flag drops, totals persist.
        vm.warp(vault.claimWindowEnd() + 1);
        vault.expireClaims();
        (funded, v2Bal, total, v1Held, active, claimed) = vault.verifySettlement();
        assertTrue(funded, "still covered");
        assertFalse(active, "window closed");
        assertEq(v1Held, 1_100_000e18, "v1 custody");
        assertEq(claimed, 600_000e18, "claimed");
    }

    function test_VerifySettlementFlagsDrainedBacking() public {
        // The alarm case the view exists for: backing leaves the vault after activation.
        _depositAndCommitAndActivate();
        vm.prank(address(vault));
        v2.checkedTransfer(address(this), 200_001e18); // leaves 899_999e18 for 1_100_000e18 outstanding

        (bool funded, uint256 v2Bal, uint256 total, uint256 v1Held, bool active, uint256 claimed) =
            vault.verifySettlement();
        assertFalse(funded, "drained");
        assertEq(v2Bal, 899_999e18, "balance");
        assertEq(total, 1_100_000e18, "outstanding");
        assertEq(claimed, 0, "claimed");
        assertTrue(active, "still live");
        assertGe(v1Held, 1_100_000e18, "v1 untouched");
    }

    // -----------------------------------------------------------------------------------------
    // Receipt reconciliation events
    // -----------------------------------------------------------------------------------------

    function test_ReceiptsCarryCumulativesAcrossSequence() public {
        vm.startPrank(alice);
        v1.approve(address(vault), type(uint256).max);

        // deposit 100 → net 100 (both events queued in emission order)
        vm.expectEmit(true, true, true, true, address(vault));
        emit MigrationVault.DepositIssued(alice, 100e18, 100e18);
        vm.expectEmit(true, true, true, true, address(vault));
        emit MigrationVault.DepositReceipt(alice, 100e18, 100e18);
        vault.deposit(100e18);

        // withdraw 40 → net 60
        vm.expectEmit(true, true, true, true, address(vault));
        emit MigrationVault.LedgerWithdrawn(alice, 40e18);
        vm.expectEmit(true, true, true, true, address(vault));
        emit MigrationVault.WithdrawalReceipt(alice, 40e18, 60e18);
        vault.withdrawV1(40e18);

        // deposit 10 → gross total 110 but NET cumulative 70: the receipts track the net
        // (statement-balance) while the legacy event keeps the gross — pinned side by side.
        vm.expectEmit(true, true, true, true, address(vault));
        emit MigrationVault.DepositIssued(alice, 10e18, 110e18);
        vm.expectEmit(true, true, true, true, address(vault));
        emit MigrationVault.DepositReceipt(alice, 10e18, 70e18);
        vault.deposit(10e18);
        vm.stopPrank();

        assertEq(vault.availableToWithdraw(alice), 70e18, "final net");
        assertEq(vault.credited(alice), 110e18, "gross unchanged by withdrawal");
    }

    function test_ReceiptsArePerAccount() public {
        vm.startPrank(alice);
        v1.approve(address(vault), 100e18);
        vm.expectEmit(true, true, true, true, address(vault));
        emit MigrationVault.DepositIssued(alice, 100e18, 100e18);
        vm.expectEmit(true, true, true, true, address(vault));
        emit MigrationVault.DepositReceipt(alice, 100e18, 100e18);
        vault.deposit(100e18);
        vm.stopPrank();

        // bob's receipt is unaffected by alice's ledger.
        vm.startPrank(bob);
        v1.approve(address(vault), 50e18);
        vm.expectEmit(true, true, true, true, address(vault));
        emit MigrationVault.DepositIssued(bob, 50e18, 50e18);
        vm.expectEmit(true, true, true, true, address(vault));
        emit MigrationVault.DepositReceipt(bob, 50e18, 50e18);
        vault.deposit(50e18);
        vm.stopPrank();

        vm.prank(alice);
        vault.withdrawV1(30e18);
        assertEq(vault.availableToWithdraw(bob), 50e18, "bob untouched");
        assertEq(vault.availableToWithdraw(alice), 70e18, "alice net");
    }

    // -----------------------------------------------------------------------------------------
    // Combined helpers
    // -----------------------------------------------------------------------------------------

    function _depositAndCommit() internal returns (bytes32[] memory leaves, uint256 total) {
        _deposit(alice, 600_000e18);
        _deposit(bob, 500_000e18);
        vm.warp(DEPOSIT_DEADLINE + 1);
        (leaves, total) = _commitSimpleRoot();
    }

    function _depositAndCommitAndActivate() internal returns (bytes32[] memory leaves, uint256 total) {
        (leaves, total) = _depositAndCommit();
        _activateClaims(total);
    }

    /// @dev Same, for a non-1:1 rate: leaves and totals are the formula applied to the deposits.
    function _depositAndCommitAndActivateAt(uint256 rateBps) internal returns (uint256 total) {
        _deposit(alice, 600_000e18);
        _deposit(bob, 500_000e18);
        vm.warp(DEPOSIT_DEADLINE + 1);
        total = (1_100_000e18 * rateBps) / 10_000;
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = TestMerkle.leaf(0, alice, (600_000e18 * rateBps) / 10_000);
        leaves[1] = TestMerkle.leaf(1, bob, (500_000e18 * rateBps) / 10_000);
        vault.commitRoot(TestMerkle.rootOf(_copy(leaves)), total);
        _activateClaims(total);
    }
}
