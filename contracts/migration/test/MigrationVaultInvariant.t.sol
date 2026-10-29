// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationVault} from "../src/MigrationVault.sol";
import {MockERC20} from "./MockERC20.sol";
import {TestMerkle} from "./TestMerkle.sol";
import {Test, Vm} from "./Base.t.sol";

/**
 * @dev ADVERSARIAL invariant + property/fuzz suite for MigrationVault (SUR-658 security review).
 *
 *      Two contracts in this file:
 *        - `MigrationHandler` — the fuzz driver. Ghost variables track every µ-unit that enters or
 *          leaves the vault through it, plus per-index claim counts, so the invariants on
 *          `MigrationVaultInvariantTest` are checked against arbitrary interleavings from
 *          arbitrary callers. Only the handler is targeted (see `targetContracts`); letting the
 *          fuzzer reach `MockERC20.mint` directly would mint value from nothing and turn
 *          conservation into noise.
 *        - `MigrationVaultInvariantTest` — the standing invariants (forge's invariant runner).
 *        - `MigrationVaultAdversarialTest` — named property tests: phase-transition matrix, bitmap
 *          boundaries (31/32/33, 63/64/65), MERKLE ADVERSARIAL section (sibling substitution,
 *          cross-account/index proof reuse, reused leaves), and the two FINDING tests that pin
 *          spec violations discovered by this review (see the report — the contract was NOT
 *          modified, per the review's rules).
 *
 *      House conventions follow contracts/payments/test/WorkspaceReceiver.invariants.t.sol:
 *      no forge-std, targeted only at the handler, assertions revert on failure.
 */
contract MigrationHandler {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint256 internal constant ACTORS = 5;
    // 70 leaves so indices 31/32/33 and 63/64/65 (bitmap word boundaries) are all in-tree.
    uint256 internal constant TREE_SIZE = 70;
    uint256 internal constant DEPOSIT_DEADLINE = 2_000_000;
    uint256 internal constant COMMIT_DEADLINE = DEPOSIT_DEADLINE + 3 days;
    uint256 internal constant EXECUTION_WINDOW = 7 days;

    MockERC20 public immutable v1;
    MockERC20 public immutable v2;
    MigrationVault public immutable vault;
    /// @dev Where withdrawV1ForSettlement sends v1 (the operator's settlement executor stand-in).
    address public immutable SINK = address(0x51CC);

    address[ACTORS] public actors;
    address[TREE_SIZE] public accounts;
    uint256[TREE_SIZE] public amounts;
    bytes32[TREE_SIZE] public leaves;
    bytes32[][] public proofs;
    bytes32 public treeRoot;
    uint256 public treeTotal;

    // -----------------------------------------------------------------------------------------
    // Ghost variables (the right-hand sides of conservation)
    // -----------------------------------------------------------------------------------------
    uint256 public ghostV1Deposited; // Σ v1 the handler minted AND deposited
    uint256 public ghostV2Funded; // Σ v2 the handler minted into the vault (operator backing)
    uint256 public ghostLedgerWithdrawn; // Σ successful withdrawV1 amounts
    uint256 public ghostRefunded; // Σ successful refund() payouts (v1, from the ledger)
    uint256 public ghostSettled; // Σ successful withdrawV1ForSettlement amounts (v1)
    uint256 public ghostSwept; // Σ v2 swept out via sweepResidual
    uint256 public ghostClaimSum; // Σ successful claim() leaf amounts
    mapping(uint256 index => uint256 count) public ghostClaimsByIndex; // successful claim() per index
    bool public ghostCommitted;
    bool public ghostEverActivated;
    bool public ghostLastActivationBacked; // v2 balance >= totalClaimable at last activation

    // ORDERING violation detectors (each must stay false — see invariant_OrderingHolds).
    bool public detectorSettledWhileInactive; // v1 left for settlement before claims ever went live
    bool public detectorExpiredWhileActive; // expireExecution flipped phase while claims were live
    bool public detectorRefundWhileActive; // refund() paid v1 while claims were still live
    bool public detectorWithdrawAfterDeadline; // withdrawV1 paid while Open past the deposit deadline

    /// @param claimPeriod 0 fuzzes never-expiring claims; a positive value fuzzes expiring ones.
    constructor(uint256 claimPeriod) {
        v1 = new MockERC20("Surplus v1", "SURPLUS");
        v2 = new MockERC20("Surplus v2", "SURPLUS2");
        // rate 0, pro-rata off: attack the base surface
        vault = new MigrationVault(
            v1, v2, DEPOSIT_DEADLINE, COMMIT_DEADLINE, EXECUTION_WINDOW, claimPeriod, 0, false, address(this)
        );

        for (uint256 i; i < ACTORS; ++i) {
            actors[i] = vm.addr(uint256(keccak256(abi.encodePacked("actor", i))));
            v1.mint(actors[i], 1_000_000e18);
        }

        bytes32[] memory buf = new bytes32[](TREE_SIZE);
        for (uint256 i; i < TREE_SIZE; ++i) {
            address who = vm.addr(uint256(keccak256(abi.encodePacked("leaf", i))));
            uint256 amt = 1_000e18 * (i + 1);
            accounts[i] = who;
            amounts[i] = amt;
            leaves[i] = TestMerkle.leaf(i, who, amt);
            buf[i] = leaves[i];
        }
        proofs = new bytes32[][](TREE_SIZE);
        treeRoot = TestMerkle.rootOf(_copy(buf));
        treeTotal = 1_000e18 * (TREE_SIZE * (TREE_SIZE + 1) / 2);
        for (uint256 i; i < TREE_SIZE; ++i) {
            proofs[i] = TestMerkle.proofFor(_copy(buf), i);
        }
    }

    // -----------------------------------------------------------------------------------------
    // Fuzz entry points
    // -----------------------------------------------------------------------------------------

    /// @dev Deposit from an arbitrary actor. Always mints fresh v1 first so conservation has a
    ///      definite right-hand side.
    function deposit(uint8 actorSeed, uint96 amount) external {
        if (amount == 0) return;
        address actor = actors[actorSeed % ACTORS];
        vm.startPrank(actor);
        v1.mint(actor, amount);
        v1.approve(address(vault), amount);
        try vault.deposit(amount) {
            ghostV1Deposited += amount;
        } catch {}
        vm.stopPrank();
    }

    function withdrawLedger(uint8 actorSeed, uint96 amount) external {
        if (amount == 0) return;
        address actor = actors[actorSeed % ACTORS];
        bool frozen = vault.phase() == MigrationVault.Phase.Open && block.timestamp > DEPOSIT_DEADLINE;
        vm.startPrank(actor);
        try vault.withdrawV1(amount) {
            ghostLedgerWithdrawn += amount;
            if (frozen) detectorWithdrawAfterDeadline = true;
        } catch {}
        vm.stopPrank();
    }

    /// @dev The Safe went silent: past the commit deadline anyone cancels.
    function expireCommit() external {
        _warpAtLeast(COMMIT_DEADLINE + 1);
        try vault.expireCommit() {} catch {}
    }

    function commitRoot() external {
        _warpAtLeast(DEPOSIT_DEADLINE + 1);
        try vault.commitRoot(treeRoot, treeTotal) {
            ghostCommitted = true;
        } catch {}
    }

    /// @dev Operator posts (or over-posts) v2 backing. Minted straight to the vault, exactly how
    ///      the SUR-662 multisig would fund it.
    function fundV2(uint96 amount) external {
        if (amount == 0) return;
        v2.mint(address(vault), amount);
        ghostV2Funded += amount;
    }

    function activateClaims() external {
        try vault.activateClaims() {
            ghostEverActivated = true;
            ghostLastActivationBacked = v2.balanceOf(address(vault)) >= vault.totalClaimable();
        } catch {}
    }

    /// @dev Root claim from an ARBITRARY caller (relayer model — payout must go to the leaf).
    function claim(uint16 seed, address caller) external {
        uint256 i = seed % TREE_SIZE;
        vm.prank(caller);
        try vault.claim(i, accounts[i], amounts[i], proofs[i]) {
            ghostClaimsByIndex[i] += 1;
            ghostClaimSum += amounts[i];
        } catch {}
    }

    /// @dev Relayed ledger refund for an arbitrary depositor, from an arbitrary caller.
    function refund(uint8 actorSeed, address caller) external {
        address actor = actors[actorSeed % ACTORS];
        uint256 owed = vault.availableToWithdraw(actor);
        bool wasActive = vault.claimsActive();
        vm.prank(caller);
        try vault.refund(actor) {
            ghostRefunded += owed;
            if (wasActive) detectorRefundWhileActive = true;
        } catch {}
    }

    function expireExecution() external {
        if (vault.rootCommittedAt() == 0) return;
        _warpAtLeast(vault.rootCommittedAt() + EXECUTION_WINDOW + 1);
        bool wasActive = vault.claimsActive();
        try vault.expireExecution() {
            if (wasActive) detectorExpiredWhileActive = true;
        } catch {}
    }

    function expireClaims() external {
        if (!vault.claimsActive()) return;
        _warpPastClaimWindow();
        try vault.expireClaims() {} catch {}
    }

    function withdrawForSettlement(uint96 amount) external {
        if (amount == 0) return;
        bool active = vault.claimsActive();
        try vault.withdrawV1ForSettlement(SINK, amount) {
            ghostSettled += amount;
            if (!active) detectorSettledWhileInactive = true;
        } catch {}
    }

    function sweepResidual() external {
        _warpPastClaimWindow();
        uint256 before = v2.balanceOf(address(vault));
        try vault.sweepResidual() {
            ghostSwept += before - v2.balanceOf(address(vault));
        } catch {}
    }

    /// @dev Sweep WITHOUT warping: while claims are open only the excess above open entitlements
    ///      may leave (checked by invariant_OpenEntitlementsStayBacked).
    function sweepInWindow() external {
        uint256 before = v2.balanceOf(address(vault));
        try vault.sweepResidual() {
            ghostSwept += before - v2.balanceOf(address(vault));
        } catch {}
    }

    // -----------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------

    function _warpAtLeast(uint256 t) internal {
        if (block.timestamp < t) vm.warp(t);
    }

    /// @dev No-op for never-expiring claims, whose window end is type(uint256).max.
    function _warpPastClaimWindow() internal {
        uint256 end = vault.claimWindowEnd();
        if (end != 0 && end != type(uint256).max) _warpAtLeast(end + 1);
    }

    function _copy(bytes32[] memory src) internal pure returns (bytes32[] memory dst) {
        dst = new bytes32[](src.length);
        for (uint256 i; i < src.length; ++i) {
            dst[i] = src[i];
        }
    }
}

contract MigrationVaultInvariantTest is Test {
    MigrationHandler internal handler;

    // Targeting: without this the fuzzer reaches MockERC20.mint and conservation becomes noise.
    address[] private _targeted;

    function setUp() public {
        handler = new MigrationHandler(_claimPeriod());
        _targeted.push(address(handler));
    }

    /// @dev Expiring claims here; the no-expiry deployment is fuzzed by the subclass below.
    function _claimPeriod() internal pure virtual returns (uint256) {
        return 180 days;
    }

    function targetContracts() public view returns (address[] memory) {
        return _targeted;
    }

    // -----------------------------------------------------------------------------------------
    // (1) CONSERVATION — no value is ever created or destroyed on either token leg
    // -----------------------------------------------------------------------------------------

    /// @dev v2: every paid claim + every swept residual + what is still in the vault == what the
    ///      operator ever funded. Nothing was minted from nothing, nothing leaked.
    function invariant_ConservationV2() public view {
        assertEq(
            handler.vault().totalClaimedAmount() + handler.ghostSwept()
                + handler.v2().balanceOf(address(handler.vault())),
            handler.ghostV2Funded(),
            "CONSERVATION(v2): claims + sweep + custody != funded"
        );
    }

    /// @dev v1: custody + ledger withdrawals + refunds + v1 out for settlement == ever deposited.
    ///      The refund and settlement legs can never conjure v1 that was not deposited.
    function invariant_ConservationV1() public view {
        assertEq(
            handler.v1().balanceOf(address(handler.vault())) + handler.ghostLedgerWithdrawn() + handler.ghostRefunded()
                + handler.ghostSettled(),
            handler.ghostV1Deposited(),
            "CONSERVATION(v1): custody + withdrawals + refunds + settlement != deposited"
        );
    }

    // -----------------------------------------------------------------------------------------
    // (2) DOUBLE-CLAIM — no account+path combination ever pays twice for one index
    // -----------------------------------------------------------------------------------------

    /// @dev The bitmap must make each index payable at most once, and the contract's own
    ///      accumulator must exactly match the ghost sum. (Refunds are keyed by account on the
    ///      ledger, so they are bounded by invariant_LedgerNeverOverdrawn instead.)
    function invariant_NoIndexEverPaidTwice() public view {
        for (uint256 i; i < 70; ++i) {
            assertTrue(handler.ghostClaimsByIndex(i) <= 1, "DOUBLE-CLAIM: index paid twice");
        }
        assertEq(
            handler.vault().totalClaimedAmount(),
            handler.ghostClaimSum(),
            "DOUBLE-CLAIM: totalClaimedAmount drifted from observed payouts"
        );
    }

    // -----------------------------------------------------------------------------------------
    // (3) ORDERING — v1 never leaves before claims are live; activation always fully backed
    // -----------------------------------------------------------------------------------------

    function invariant_OrderingHolds() public view {
        assertTrue(!handler.detectorSettledWhileInactive(), "ORDERING: v1 left for settlement before claims active");
        assertTrue(
            !handler.detectorExpiredWhileActive(),
            "ORDERING: expireExecution flipped to refunds while claims were live (see FINDING F1)"
        );
        assertTrue(
            !handler.detectorRefundWhileActive(), "ORDERING: refund() paid v1 while claims were live (see FINDING F1)"
        );
        assertTrue(
            !handler.detectorWithdrawAfterDeadline(), "ORDERING: ledger withdrawal after the deposit deadline (P1)"
        );
        if (handler.ghostEverActivated()) {
            assertTrue(handler.ghostLastActivationBacked(), "ORDERING: activation with v2 < totalClaimable");
        }
    }

    // -----------------------------------------------------------------------------------------
    // (4) LEDGER — credited >= 0, withdrawals never exceed credited, net math exact
    // -----------------------------------------------------------------------------------------

    function invariant_LedgerNeverOverdrawn() public view {
        // availableToWithdraw panics on underflow, so any actor with withdrawn > credited fails
        // this view outright. Ghost sums must agree with the contract's accumulators exactly.
        for (uint256 i; i < 5; ++i) {
            handler.vault().availableToWithdraw(handler.actors(i));
        }
        assertTrue(
            handler.vault().totalLedgerWithdrawnV1() <= handler.vault().totalDepositedV1(),
            "LEDGER: total withdrawn exceeds total deposited"
        );
    }

    // -----------------------------------------------------------------------------------------
    // (5)+(6) PHASES / ROOT — after commitment, no path mutates root or totalClaimable
    // -----------------------------------------------------------------------------------------

    function invariant_RootIsImmutableAfterCommit() public view {
        if (handler.ghostCommitted()) {
            assertEq(handler.vault().root(), handler.treeRoot(), "ROOT: root changed after commitRoot");
            assertEq(handler.vault().totalClaimable(), handler.treeTotal(), "ROOT: totalClaimable changed");
        }
    }

    // -----------------------------------------------------------------------------------------
    // (7) BACKING — a sweep never takes an entitlement that can still be claimed
    // -----------------------------------------------------------------------------------------

    function invariant_OpenEntitlementsStayBacked() public view {
        MigrationVault vault = handler.vault();
        // Payouts never pass the committed total (oracle review): `open` below can never underflow.
        assertGe(vault.totalClaimable(), vault.totalClaimedAmount(), "PAYOUT: paid past the committed total");
        if (!vault.claimsEverActive() || block.timestamp > vault.claimWindowEnd()) return;
        uint256 open = vault.totalClaimable() - vault.totalClaimedAmount();
        assertGe(handler.v2().balanceOf(address(vault)), open, "BACKING: a sweep took an open entitlement");
    }
}

/// @dev The same invariants against a never-expiring deployment (CLAIM_PERIOD == 0, P5 option A).
contract MigrationVaultNoExpiryInvariantTest is MigrationVaultInvariantTest {
    function _claimPeriod() internal pure override returns (uint256) {
        return 0;
    }
}

/**
 * @dev Named adversarial property tests. Independent of the invariant runner: each test builds its
 *      own world, drives the phase machine to the state under attack, and asserts.
 */
contract MigrationVaultAdversarialTest is Test {
    MockERC20 internal v1;
    MockERC20 internal v2;
    MigrationVault internal vault;

    address internal alice;
    address internal bob;
    address internal relayer;

    uint256 internal constant DEPOSIT_DEADLINE = 2_000_000;
    uint256 internal constant EXECUTION_WINDOW = 7 days;
    uint256 internal constant CLAIM_PERIOD = 180 days;

    function setUp() public {
        _freshVault();
    }

    // -----------------------------------------------------------------------------------------
    // World-building helpers
    // -----------------------------------------------------------------------------------------

    function _freshVault() internal {
        v1 = new MockERC20("Surplus v1", "SURPLUS");
        v2 = new MockERC20("Surplus v2", "SURPLUS2");
        // rate 0, pro-rata off: attack the base surface
        vault = new MigrationVault(
            v1, v2, DEPOSIT_DEADLINE, DEPOSIT_DEADLINE + 3 days, EXECUTION_WINDOW, CLAIM_PERIOD, 0, false, address(this)
        );
        alice = _addr("alice");
        bob = _addr("bob");
        relayer = _addr("relayer");
        v1.mint(alice, 1_000_000e18);
        v1.mint(bob, 1_000_000e18);
        v2.mint(address(this), 1_000_000_000e18);
    }

    function _addr(string memory label) internal returns (address a) {
        a = vm.addr(uint256(keccak256(abi.encodePacked(label))));
        vm.label(a, label);
    }

    function _deposit(address who, uint256 amount) internal {
        vm.startPrank(who);
        v1.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    /// @dev The canonical small tree: idx0 alice 100e18, idx1 bob 50e18. Returns leaves (a COPY —
    ///      TestMerkle collapses arrays in place, so every root/proof derivation needs its own).
    function _smallTree() internal view returns (bytes32[] memory l, uint256 total) {
        l = new bytes32[](2);
        l[0] = TestMerkle.leaf(0, alice, 100e18);
        l[1] = TestMerkle.leaf(1, bob, 50e18);
        total = 150e18;
    }

    function _commit(bytes32[] memory l, uint256 total) internal {
        vm.warp(DEPOSIT_DEADLINE + 1);
        vault.commitRoot(TestMerkle.rootOf(_copy(l)), total);
    }

    function _fundAndActivate(uint256 total) internal {
        v2.checkedTransfer(address(vault), total);
        vault.activateClaims();
    }

    function _proof(bytes32[] memory l, uint256 index) internal pure returns (bytes32[] memory) {
        return TestMerkle.proofFor(_copy(l), index);
    }

    function _copy(bytes32[] memory src) internal pure returns (bytes32[] memory dst) {
        dst = new bytes32[](src.length);
        for (uint256 i; i < src.length; ++i) {
            dst[i] = src[i];
        }
    }

    /// @dev 70-leaf tree over distinct derived accounts — covers bitmap boundaries 31/32/33/63/64/65.
    function _bigTree() internal pure returns (bytes32[] memory l, uint256 total, uint256[70] memory amt) {
        l = new bytes32[](70);
        for (uint256 i; i < 70; ++i) {
            address who = vm.addr(uint256(keccak256(abi.encodePacked("adv-leaf", i))));
            amt[i] = 1_000e18 * (i + 1);
            l[i] = TestMerkle.leaf(i, who, amt[i]);
            total += amt[i];
        }
    }

    // =========================================================================================
    // (5) PHASE-TRANSITION MATRIX — every state-mutating function in every wrong phase reverts.
    //     Built cell-by-cell on fresh vaults so each phase is tested from a clean world.
    //     (Two cells are deliberately NOT asserted here because the contract violates the spec in
    //     them — they are pinned as FINDING tests below: expireExecution while claims are live, and
    //     re-activation after the claim window expired.)
    // =========================================================================================

    function test_PhaseMatrix_Open() public {
        _deposit(alice, 10e18);
        // withdrawV1 allowed while open
        vm.prank(alice);
        vault.withdrawV1(3e18);
        // everything else is wrong for this phase:
        vm.expectRevert(
            abi.encodeWithSelector(MigrationVault.DeadlineNotPassed.selector, DEPOSIT_DEADLINE, block.timestamp)
        );
        vault.commitRoot(bytes32(uint256(1)), 1e18);
        vm.expectRevert(MigrationVault.NotCommitted.selector);
        vault.activateClaims();
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.claim(0, alice, 1e18, new bytes32[](0));
        vm.expectRevert(MigrationVault.NotRefundPhase.selector);
        vault.refund(alice);
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.withdrawV1ForSettlement(address(this), 1e18);
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.expireClaims();
        vm.expectRevert(MigrationVault.ClaimsStillActive.selector);
        vault.sweepResidual();
        vm.expectRevert(MigrationVault.NotCommitted.selector);
        vault.expireExecution();
    }

    function test_PhaseMatrix_CommittedPreActivation() public {
        (bytes32[] memory l, uint256 total) = _smallTree();
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _commit(l, total);
        vm.startPrank(alice);
        v1.approve(address(vault), 1e18);
        vm.expectRevert(MigrationVault.NotOpen.selector);
        vault.deposit(1e18);
        vm.expectRevert(MigrationVault.LedgerWithdrawalsFrozen.selector);
        vault.withdrawV1(1e18);
        vm.stopPrank();
        vm.expectRevert(MigrationVault.NotOpen.selector);
        vault.commitRoot(bytes32(uint256(1)), 1e18);
        vm.expectRevert(MigrationVault.NotOpen.selector);
        vault.cancel();
        // underfunded activation is refused (ordering rule gate)
        v2.checkedTransfer(address(vault), total - 1);
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.InsufficientBacking.selector, total, total - 1));
        vault.activateClaims();
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.claim(0, alice, 100e18, _proof(l, 0));
        vm.expectRevert(MigrationVault.NotRefundPhase.selector);
        vault.refund(alice);
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.withdrawV1ForSettlement(address(this), 1e18);
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.expireClaims();
        vm.expectRevert(MigrationVault.ClaimsStillActive.selector);
        vault.sweepResidual();
        vm.expectRevert(
            abi.encodeWithSelector(
                MigrationVault.ExecutionWindowStillOpen.selector,
                vault.rootCommittedAt() + EXECUTION_WINDOW,
                block.timestamp
            )
        );
        vault.expireExecution();
    }

    function test_PhaseMatrix_ClaimsActive() public {
        (bytes32[] memory l, uint256 total) = _smallTree();
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _commit(l, total);
        _fundAndActivate(total);
        vm.startPrank(alice);
        v1.approve(address(vault), 1e18);
        vm.expectRevert(MigrationVault.NotOpen.selector);
        vault.deposit(1e18);
        vm.expectRevert(MigrationVault.LedgerWithdrawalsFrozen.selector);
        vault.withdrawV1(1e18);
        vm.stopPrank();
        vm.expectRevert(MigrationVault.NotOpen.selector);
        vault.commitRoot(bytes32(uint256(1)), 1e18);
        vm.expectRevert(MigrationVault.NotOpen.selector);
        vault.cancel();
        vm.expectRevert(MigrationVault.ClaimsAlreadyActive.selector);
        vault.activateClaims();
        // the allowed cells actually work, from a non-beneficiary caller:
        vm.prank(relayer);
        vault.claim(0, alice, 100e18, _proof(l, 0));
        vault.withdrawV1ForSettlement(address(this), 150e18);
        vm.expectRevert(MigrationVault.NotRefundPhase.selector);
        vault.refund(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                MigrationVault.ClaimWindowStillOpen.selector, vault.claimWindowEnd(), block.timestamp
            )
        );
        vault.expireClaims();
        // in-window the sweep may take only the excess above open entitlements, and there is none
        vm.expectRevert(MigrationVault.NothingToSweep.selector);
        vault.sweepResidual();
    }

    function test_PhaseMatrix_ClaimsExpired() public {
        (bytes32[] memory l, uint256 total) = _smallTree();
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _commit(l, total);
        _fundAndActivate(total);
        vm.warp(vault.claimWindowEnd() + 1);
        vault.expireClaims();
        vm.startPrank(alice);
        v1.approve(address(vault), 1e18);
        vm.expectRevert(MigrationVault.NotOpen.selector);
        vault.deposit(1e18);
        vm.expectRevert(MigrationVault.LedgerWithdrawalsFrozen.selector);
        vault.withdrawV1(1e18);
        vm.stopPrank();
        vm.expectRevert(MigrationVault.NotOpen.selector);
        vault.commitRoot(bytes32(uint256(1)), 1e18);
        vm.expectRevert(MigrationVault.NotOpen.selector);
        vault.cancel();
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.claim(0, alice, 100e18, _proof(l, 0));
        vm.expectRevert(MigrationVault.NotRefundPhase.selector);
        vault.refund(alice);
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.withdrawV1ForSettlement(address(this), 1e18);
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.expireClaims();
        // expiring claims (CLAIM_PERIOD > 0): the unclaimed remainder goes to the owner (P5)
        vault.sweepResidual();
        assertEq(v2.balanceOf(address(vault)), 0, "nothing frozen after expiry");
        // NOTE: expireExecution is NOT asserted to revert here — after the claim window expired
        // it is still callable (phase never left Committed): that cell IS FINDING F1, pinned in
        // test_Finding_F1 below. Everything else in this phase reverts.
    }

    function test_PhaseMatrix_CancelledPreRoot() public {
        _deposit(alice, 10e18);
        vault.cancel();
        vm.startPrank(alice);
        v1.approve(address(vault), 1e18);
        vm.expectRevert(MigrationVault.NotOpen.selector);
        vault.deposit(1e18);
        vault.withdrawV1(10e18); // the sanctioned exit
        vm.stopPrank();
        vm.expectRevert(MigrationVault.NotOpen.selector);
        vault.commitRoot(bytes32(uint256(1)), 1e18);
        vm.expectRevert(MigrationVault.NotOpen.selector);
        vault.cancel();
        vm.expectRevert(MigrationVault.NotCommitted.selector);
        vault.activateClaims();
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.claim(0, alice, 1e18, new bytes32[](0));
        vm.expectRevert(MigrationVault.NothingToWithdraw.selector); // alice already took her whole credit
        vault.refund(alice);
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.withdrawV1ForSettlement(address(this), 1e18);
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.expireClaims();
        vm.expectRevert(MigrationVault.NothingToSweep.selector); // sweepable (Cancelled), but no v2 here
        vault.sweepResidual();
        vm.expectRevert(MigrationVault.NotCommitted.selector);
        vault.expireExecution();
    }

    function test_PhaseMatrix_CancelledPostRoot() public {
        (bytes32[] memory l,) = _smallTree();
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _commit(l, 150e18);
        vm.warp(vault.rootCommittedAt() + EXECUTION_WINDOW + 1);
        vault.expireExecution(); // permissionless
        vm.startPrank(alice);
        v1.approve(address(vault), 1e18);
        vm.expectRevert(MigrationVault.NotOpen.selector);
        vault.deposit(1e18);
        vault.withdrawV1(1e18); // a ledger exit: the same credit the refund below draws on
        vm.stopPrank();
        vm.expectRevert(MigrationVault.NotOpen.selector);
        vault.commitRoot(bytes32(uint256(1)), 1e18);
        vm.expectRevert(MigrationVault.NotOpen.selector);
        vault.cancel();
        vm.expectRevert(MigrationVault.NotCommitted.selector);
        vault.activateClaims();
        vm.prank(relayer);
        vault.refund(alice); // the sanctioned push exit: pays the remaining 99
        assertEq(vault.availableToWithdraw(alice), 0, "alice exited exactly once");
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.claim(0, alice, 100e18, _proof(l, 0));
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.withdrawV1ForSettlement(address(this), 1e18);
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.expireClaims();
        vm.expectRevert(MigrationVault.NothingToSweep.selector); // sweepable (Cancelled), but no v2 here
        vault.sweepResidual();
        vm.expectRevert(MigrationVault.NotCommitted.selector);
        vault.expireExecution();
    }

    // =========================================================================================
    // (2) DOUBLE-CLAIM — bitmap integrity across word boundaries 31/32/33 and 63/64/65
    // =========================================================================================

    function test_Adv_BitmapBoundaries_ClaimOnceThenLocked() public {
        (bytes32[] memory l, uint256 total, uint256[70] memory amt) = _bigTree();
        _commit(l, total);
        _fundAndActivate(total);
        uint256[6] memory bounds = [uint256(31), 32, 33, 63, 64, 65];
        for (uint256 k; k < bounds.length; ++k) {
            uint256 i = bounds[k];
            assertFalse(vault.isClaimed(i), "pre-claim bitmap dirty");
            address who = vm.addr(uint256(keccak256(abi.encodePacked("adv-leaf", i))));
            vm.prank(relayer);
            vault.claim(i, who, amt[i], _proof(l, i));
            assertTrue(vault.isClaimed(i), "post-claim bitmap missing");
            assertEq(v2.balanceOf(who), amt[i], "boundary claim unpaid");
        }
        // every boundary index is now double-claim-proof, even with mutated amount/account/proof
        for (uint256 k; k < bounds.length; ++k) {
            uint256 i = bounds[k];
            address who = vm.addr(uint256(keccak256(abi.encodePacked("adv-leaf", i))));
            vm.prank(relayer);
            vm.expectRevert(abi.encodeWithSelector(MigrationVault.AlreadyClaimed.selector, i));
            vault.claim(i, who, amt[i] + 1, _proof(l, i));
            vm.prank(relayer);
            vm.expectRevert(abi.encodeWithSelector(MigrationVault.AlreadyClaimed.selector, i));
            vault.claim(i, bob, amt[i], _proof(l, i));
        }
        // neighbours stay claimable (no cross-word contamination)
        uint256[4] memory near = [uint256(30), 62, 66, 69];
        for (uint256 k; k < near.length; ++k) {
            uint256 i = near[k];
            address who = vm.addr(uint256(keccak256(abi.encodePacked("adv-leaf", i))));
            vm.prank(relayer);
            vault.claim(i, who, amt[i], _proof(l, i));
        }
    }

    function test_Adv_RefundsPayTheLedgerAndIgnoreTheRoot() public {
        // Refunds draw on the deposit ledger (review finding P3): a leaf account that never
        // deposited gets nothing, a depositor is refunded exactly once however the root allocated
        // them, and the claim bitmap is never touched.
        (bytes32[] memory l, uint256 total,) = _bigTree();
        v1.mint(alice, total);
        _deposit(alice, total);
        _commit(l, total);
        vm.warp(vault.rootCommittedAt() + EXECUTION_WINDOW + 1);
        vault.expireExecution();
        address who32 = vm.addr(uint256(keccak256(abi.encodePacked("adv-leaf", uint256(32)))));
        vm.prank(relayer);
        vm.expectRevert(MigrationVault.NothingToWithdraw.selector);
        vault.refund(who32);
        vm.prank(relayer);
        vault.refund(alice);
        assertEq(v1.balanceOf(address(vault)), 0, "alice's deposit fully returned");
        vm.prank(relayer);
        vm.expectRevert(MigrationVault.NothingToWithdraw.selector);
        vault.refund(alice);
        assertFalse(vault.isClaimed(32), "refunds never touch the claim bitmap");
    }

    // =========================================================================================
    // MERKLE ADVERSARIAL — proof forgery attempts against the committed root
    // =========================================================================================

    function test_Adv_SiblingSubstitutionFails() public {
        (bytes32[] memory l, uint256 total) = _smallTree();
        _commit(l, total);
        _fundAndActivate(total);
        bytes32[] memory p = _proof(l, 0);
        p[0] = bytes32(uint256(p[0]) ^ 1); // flip one bit of the sibling hash
        vm.expectRevert(MigrationVault.InvalidProof.selector);
        vault.claim(0, alice, 100e18, p);
    }

    function test_Adv_ProofOfAAgainstBFails() public {
        (bytes32[] memory l, uint256 total) = _smallTree();
        _commit(l, total);
        _fundAndActivate(total);
        vm.prank(relayer);
        vm.expectRevert(MigrationVault.InvalidProof.selector);
        vault.claim(0, bob, 100e18, _proof(l, 0)); // alice's proof, bob as beneficiary
    }

    function test_Adv_ProofIndexSwapFails() public {
        (bytes32[] memory l, uint256 total) = _smallTree();
        _commit(l, total);
        _fundAndActivate(total);
        vm.expectRevert(MigrationVault.InvalidProof.selector);
        vault.claim(1, alice, 100e18, _proof(l, 0)); // leaf binds the index — proof(0) != leaf(1)
        vm.expectRevert(MigrationVault.InvalidProof.selector);
        vault.claim(0, alice, 50e18, _proof(l, 1)); // ...and the amount
    }

    function test_Adv_TruncatedAndExtendedProofsFail() public {
        (bytes32[] memory l, uint256 total,) = _bigTree();
        _commit(l, total);
        _fundAndActivate(total);
        address who = vm.addr(uint256(keccak256(abi.encodePacked("adv-leaf", uint256(5)))));
        bytes32[] memory p = _proof(l, 5);
        bytes32[] memory short = new bytes32[](p.length - 1);
        for (uint256 i; i < short.length; ++i) {
            short[i] = p[i];
        }
        vm.expectRevert(MigrationVault.InvalidProof.selector);
        vault.claim(5, who, 6_000e18, short);
        bytes32[] memory long = new bytes32[](p.length + 1);
        for (uint256 i; i < p.length; ++i) {
            long[i] = p[i];
        }
        long[p.length] = bytes32(uint256(1));
        vm.expectRevert(MigrationVault.InvalidProof.selector);
        vault.claim(5, who, 6_000e18, long);
        vm.expectRevert(MigrationVault.InvalidProof.selector);
        vault.claim(5, who, 6_000e18, new bytes32[](0));
    }

    /// @dev Two IDENTICAL entitlements at different indices both pay — the vault cannot detect
    ///      duplicate leaves; this pins that responsibility on the tree build (DESIGN.md §9).
    function test_Adv_ReusedLeafAtDifferentIndicesPaysTwice() public {
        // leaves: 0=(alice,X) 1=(bob,Y) 2=(alice,X again) 3=(bob,Z)
        uint256 x = 100e18;
        uint256 y = 50e18;
        uint256 z = 7e18;
        bytes32[] memory l = new bytes32[](4);
        l[0] = TestMerkle.leaf(0, alice, x);
        l[1] = TestMerkle.leaf(1, bob, y);
        l[2] = TestMerkle.leaf(2, alice, x);
        l[3] = TestMerkle.leaf(3, bob, z);
        _deposit(alice, x);
        _deposit(bob, y + z);
        _commit(l, x + x + y + z);
        _fundAndActivate(x + x + y + z);
        vault.claim(0, alice, x, _proof(l, 0));
        vault.claim(2, alice, x, _proof(l, 2)); // succeeds: distinct index = distinct entitlement
        assertEq(v2.balanceOf(alice), 2 * x, "duplicate leaf paid twice (documented, by design)");
    }

    // =========================================================================================
    // (6) ROOT — refunds pay exactly the ledger credit; window edges are inclusive-exclusive
    // =========================================================================================

    function test_Adv_RefundPaysExactlyLedgerCredit() public {
        (bytes32[] memory l, uint256 total,) = _bigTree();
        v1.mint(alice, total);
        _deposit(alice, total);
        _deposit(bob, 7e18);
        _commit(l, total);
        vm.warp(vault.rootCommittedAt() + EXECUTION_WINDOW + 1);
        vault.expireExecution();
        uint256 before = v1.balanceOf(bob);
        vm.prank(relayer);
        vault.refund(bob);
        assertEq(v1.balanceOf(bob) - before, 7e18, "refund != ledger credit");
    }

    function test_Adv_ClaimAtExactWindowEndSucceeds() public {
        (bytes32[] memory l, uint256 total) = _smallTree();
        _commit(l, total);
        _fundAndActivate(total);
        vm.warp(vault.claimWindowEnd()); // inclusive
        vault.claim(0, alice, 100e18, _proof(l, 0));
    }

    function test_Adv_DepositAtExactDeadlineSucceeds() public {
        vm.warp(DEPOSIT_DEADLINE); // inclusive
        _deposit(alice, 1e18);
        assertEq(vault.credited(alice), 1e18, "boundary deposit");
    }

    // =========================================================================================
    // Bounded fuzz drivers (properties too stateful for the invariant runner)
    // =========================================================================================

    /// @dev (2) A valid leaf pays its beneficiary exactly once, from ANY caller; every mutated
    ///      replay of the same index reverts AlreadyClaimed (bitmap precedes verification).
    function test_Fuzz_ClaimAnyCallerThenAllReplaysLocked(
        uint16 seed,
        address caller,
        uint96 fakeAmount,
        address fakeAcc
    ) public {
        (bytes32[] memory l, uint256 total, uint256[70] memory amt) = _bigTree();
        _commit(l, total);
        _fundAndActivate(total);
        uint256 i = seed % 70;
        address who = vm.addr(uint256(keccak256(abi.encodePacked("adv-leaf", i))));
        vm.prank(caller);
        vault.claim(i, who, amt[i], _proof(l, i));
        assertEq(v2.balanceOf(who), amt[i], "beneficiary not paid exactly the leaf");
        assertEq(vault.totalClaimedAmount(), amt[i], "accumulator drift");
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.AlreadyClaimed.selector, i));
        vault.claim(i, who, amt[i], _proof(l, i));
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.AlreadyClaimed.selector, i));
        vault.claim(i, fakeAcc, fakeAmount, _proof(l, i));
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.AlreadyClaimed.selector, i));
        vault.claim(i, who, amt[i] + uint256(fakeAmount) + 1, new bytes32[](0));
    }

    /// @dev (2) Bitmap word boundaries under fuzz: pre-claimed 31/32/33/63/64/65 reject every
    ///      second attempt regardless of amount/account/proof shape.
    function test_Fuzz_DoubleClaimAtWordBoundaries(uint8 pick, uint96 fakeAmount, address fakeAcc) public {
        (bytes32[] memory l, uint256 total, uint256[70] memory amt) = _bigTree();
        _commit(l, total);
        _fundAndActivate(total);
        uint256[6] memory bounds = [uint256(31), 32, 33, 63, 64, 65];
        uint256 i = bounds[pick % 6];
        address who = vm.addr(uint256(keccak256(abi.encodePacked("adv-leaf", i))));
        vault.claim(i, who, amt[i], _proof(l, i));
        vm.prank(fakeAcc);
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.AlreadyClaimed.selector, i));
        vault.claim(i, who, fakeAmount, _proof(l, i));
    }

    /// @dev (3) No activation with v2 balance < totalClaimable, across fuzzed shortfalls; exact
    ///      funding then activates.
    function test_Fuzz_ActivationRequiresFullBacking(uint96 shortfallSeed) public {
        (bytes32[] memory l, uint256 total) = _smallTree();
        _commit(l, total);
        uint256 shortfall = uint256(shortfallSeed) % (total - 1) + 1; // 1..total-1, never 0 or full
        v2.checkedTransfer(address(vault), total - shortfall);
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.InsufficientBacking.selector, total, total - shortfall));
        vault.activateClaims();
        v2.checkedTransfer(address(vault), shortfall); // top up to exactly total
        vault.activateClaims();
        assertTrue(vault.claimsActive(), "exact funding must activate");
    }

    /// @dev (4) Net-credit math is exact under arbitrary deposit/withdraw interleavings, and
    ///      withdrawals can never exceed credited (including the amount that would overdraw).
    function test_Fuzz_LedgerInterleavingsExact(uint96 d1, uint96 w1, uint96 d2, uint96 w2) public {
        uint256 minted = 1_000_000e18;
        uint256 okD1 = _tryDeposit(alice, d1);
        uint256 okW1 = _tryWithdraw(alice, w1);
        uint256 okD2 = _tryDeposit(alice, d2);
        uint256 okW2 = _tryWithdraw(alice, w2);
        uint256 expectedNet = okD1 + okD2 - okW1 - okW2; // succeeds are bounded by availability
        assertEq(vault.credited(alice) - vault.withdrawn(alice), expectedNet, "net credit drifted");
        assertEq(v1.balanceOf(alice), minted - expectedNet, "actor v1 balance drifted");
        assertEq(v1.balanceOf(address(vault)), expectedNet, "custody drifted");
        assertTrue(vault.withdrawn(alice) <= vault.credited(alice), "overdraw");
    }

    function _tryDeposit(address who, uint256 amount) internal returns (uint256 paid) {
        if (amount == 0) return 0;
        vm.startPrank(who);
        v1.approve(address(vault), amount);
        try vault.deposit(amount) {
            paid = amount;
        } catch {}
        vm.stopPrank();
    }

    function _tryWithdraw(address who, uint256 amount) internal returns (uint256 paid) {
        if (amount == 0) return 0;
        vm.startPrank(who);
        try vault.withdrawV1(amount) {
            paid = amount;
        } catch {}
        vm.stopPrank();
    }

    // =========================================================================================
    // FINDINGS — spec violations triggered by this review. The contract was NOT modified.
    // These tests FAIL on the current contract; each failure IS the report.
    // =========================================================================================

    /**
     * FINDING F1 (HIGH) — `expireExecution` has no `claimsActive` guard (MigrationVault.sol:277).
     *
     * The spec (DESIGN.md §3, contract header): expireExecution is the remedy when the operator
     * "committed a root but failed to activate claims within EXECUTION_WINDOW", and root refunds
     * are "fully backed because v1 cannot have left". But activation inside the execution window
     * (e.g. on day 6 of 7) leaves the vault in phase Committed with claimsActive=true — and after
     * the window passes, ANYONE can still call expireExecution: it checks only
     * `phase == Committed` and the timestamp. The vault flips to Cancelled WHILE claims are live:
     *
     *   - refund() becomes callable (phase Cancelled, root set) while claim() still works —
     *     holders extract v1 refunds AND v2 claims from the same migration;
     *   - withdrawV1ForSettlement remains callable (claimsActive) — the operator can drain ALL
     *     remaining v1 after refunds opened, so "refunds fully backed by construction" is false;
     *   - the ordering rule the contract exists to enforce is broken.
     *
     * Failing sequence: deposit → commitRoot → fund v2 → activateClaims →
     * warp(rootCommittedAt + EXECUTION_WINDOW + 1) → expireExecution() [succeeds; should revert]
     * → refund(0, alice, …) ✓ && claim(1, bob, …) ✓ && withdrawV1ForSettlement(rest) ✓.
     */
    function test_Finding_F1_ExpireExecutionWhileClaimsActive() public {
        (bytes32[] memory l, uint256 total) = _smallTree();
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _commit(l, total);
        _fundAndActivate(total);
        assertTrue(vault.claimsActive(), "claims live");
        // Still deep inside the 180d claim window, but past the 7d execution window:
        vm.warp(vault.rootCommittedAt() + EXECUTION_WINDOW + 1);

        bool expired;
        try vault.expireExecution() {
            expired = true;
        } catch {}
        assertTrue(!expired, "FINDING F1: expireExecution succeeded while claimsActive - spec requires revert");

        if (expired) {
            // Impact demonstration: cross-path double payment + settlement drain after refunds open.
            vm.prank(relayer);
            vault.refund(alice); // v1 leaves via the "fully backed" path
            vm.prank(relayer);
            vault.claim(1, bob, 50e18, _proof(l, 1)); // v2 leaves via live claims, same migration
            vault.withdrawV1ForSettlement(address(0xD15EA5E), v1.balanceOf(address(vault))); // rest of v1 out
            // alice got her v1 BACK and the vault is empty of v1 while root refunds for other
            // indices are still "open" — they now revert for everyone else (funds gone).
        }
    }

    /**
     * FINDING F2 (LOW) — `activateClaims` can REOPEN the claim window after `expireClaims`
     * (MigrationVault.sol:295). The published offer fixes the window at deployment ("closed
     * deposits; long claims"); after expiry the owner can re-fund and re-activate, resetting
     * claimWindowEnd. Holder-favorable in isolation, but it contradicts "the claim window closed"
     * being terminal (ClaimsExpired event semantics) and re-enables the settlement exit after the
     * matrix says it should be dead. Sequence: activate → warp(end+1) → expireClaims →
     * activateClaims() [succeeds; should revert].
     */
    function test_Finding_F2_ClaimWindowCanBeReopened() public {
        (bytes32[] memory l, uint256 total) = _smallTree();
        _commit(l, total);
        _fundAndActivate(total);
        vm.warp(vault.claimWindowEnd() + 1);
        vault.expireClaims();
        assertFalse(vault.claimsActive(), "window closed");

        bool reopened;
        try vault.activateClaims() {
            reopened = true;
        } catch {}
        assertTrue(!reopened, "FINDING F2: activateClaims reopened the window after expireClaims");
        if (reopened) {
            assertTrue(vault.claimsActive(), "reopened");
            assertTrue(vault.claimWindowEnd() > 0, "new window end");
        }
    }
}
