// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationVault} from "../src/MigrationVault.sol";
import {MockERC20} from "./MockERC20.sol";
import {TestMerkle} from "./TestMerkle.sol";
import {Test} from "./Base.t.sol";

/// @title MiniSafe — a minimal threshold multisig for e2e rehearsal (SUR-662 pre-work).
/// @dev Deliberately NOT a real Safe: 32 lines of reviewable logic that model exactly the
///      property the vault depends on — privileged calls require m-of-n collected approvals,
///      a single signer can do nothing privileged. The real executor will be a deployed
///      Safe (SUR-662); the rehearsal asserts the vault's behavior under that ownership
///      model, not Safe's internals. Uses OZ-style execTransaction semantics compressed
///      to one pattern: collect approvals, then anyone executes the fully-approved tx.
contract MiniSafe {
    address[3] public signers;
    uint256 public immutable threshold; // e.g. 2 of 3

    mapping(bytes32 => uint256) public approvalsBitmap; // txHash -> bit i = signers[i] approved

    constructor(address[3] memory s, uint256 t) {
        signers = s;
        threshold = t;
    }

    function approveAndExecute(address target, bytes calldata data, uint8[] calldata who) external {
        bytes32 txHash = keccak256(abi.encode(target, data));
        uint256 bitmap = approvalsBitmap[txHash];
        for (uint256 i = 0; i < who.length; i++) {
            uint256 bit = uint256(1) << who[i]; // no duplicate check: duplicates just re-set a bit
            bitmap |= bit;
        }
        approvalsBitmap[txHash] = bitmap;
        require(_popcount(bitmap) >= threshold, "MiniSafe: below threshold");
        (bool ok,) = target.call(data);
        require(ok, "MiniSafe: exec reverted");
    }

    function _popcount(uint256 x) internal pure returns (uint256 c) {
        while (x != 0) {
            x &= x - 1;
            c++;
        }
    }
}

/// @notice Full lifecycle e2e under multisig control — the SUR-662 rehearsal.
contract E2EMultisigTest is Test {
    MockERC20 v1;
    MockERC20 v2;
    MigrationVault vault;

    MiniSafe safe;
    address aliceSigner;
    address bobSigner;
    address carolSigner;

    address alice; // holder
    address bob; // holder

    uint256 constant RATE = 10_000; // 1:1

    function setUp() public {
        aliceSigner = vm.addr(0xA11CE);
        bobSigner = vm.addr(0xB0B);
        carolSigner = vm.addr(0xCA401);
        alice = vm.addr(0xA1); // holder
        bob = vm.addr(0xB2); // holder
        vm.label(aliceSigner, "aliceSigner");
        vm.label(bobSigner, "bobSigner");
        vm.label(carolSigner, "carolSigner");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
        v1 = new MockERC20("Surplus v1", "SURPLUS");
        v2 = new MockERC20("Surplus v2", "SURPLUS2");
        address[3] memory signers = [aliceSigner, bobSigner, carolSigner];
        safe = new MiniSafe(signers, 2);
        vault = new MigrationVault(
            v1, v2, block.timestamp + 30 days, block.timestamp + 33 days, 7 days, 180 days, RATE, false, address(this)
        );
        v1.mint(alice, 600_000e18);
        v1.mint(bob, 400_000e18);
    }

    /// The whole migration, one rung at a time, executor = MiniSafe from the start.
    function test_E2E_FullLifecycleUnderMultisig() public {
        // --- Rung 0: hand the vault to the multisig (two-step) ------------------------------
        vault.transferOwnership(address(safe));
        vm.prank(address(safe));
        vault.acceptOwnership();
        assertEq(vault.owner(), address(safe));

        // --- Rung 1: deposits --------------------------------------------------------------
        vm.startPrank(alice);
        v1.approve(address(vault), 600_000e18);
        vault.deposit(600_000e18);
        vm.stopPrank();
        vm.startPrank(bob);
        v1.approve(address(vault), 400_000e18);
        vault.deposit(400_000e18);
        vm.stopPrank();

        // --- Rung 2: deadline passes; operator (multisig) commits the root ----------------
        (bytes32[] memory leaves, uint256 total) = _tree();
        bytes32 root = TestMerkle.rootOf(leaves);
        vm.warp(block.timestamp + 30 days + 1);
        _safeExec(abi.encodeCall(MigrationVault.commitRoot, (root, total)), vm.addr(1), vm.addr(2));

        // --- Rung 3: v2 funding must PRECEDE any v1 movement ------------------------------
        // Single signer tries to move v1 first: must fail (not just threshold — ordering).
        bytes memory bad = abi.encodeCall(MigrationVault.withdrawV1ForSettlement, (address(0xBEEF), 1e18));
        vm.prank(aliceSigner);
        (bool ok,) = address(safe).call(abi.encodeCall(MiniSafe.approveAndExecute, (address(vault), bad, _single(0))));
        assertFalse(ok, "single signer must not reach ordering check");

        // --- Rung 4: fund v2 and activate within the execution window (the happy path) ------
        // After the window (rootCommittedAt + EXECUTION_WINDOW) activation reverts and only the timeout refund
        // path remains; OracleReview.t.sol pins that.
        vm.warp(block.timestamp + 7 days);
        v2.mint(address(vault), total);
        _safeExec(abi.encodeCall(MigrationVault.activateClaims, ()), bobSigner, carolSigner);
        assertTrue(vault.claimsActive(), "claims not active");

        // --- Rung 5: settlement withdrawal via multisig, AFTER activation ------------------
        uint256 custodyBefore = v1.balanceOf(address(vault));
        _safeExec(
            abi.encodeCall(MigrationVault.withdrawV1ForSettlement, (address(0xBEEF), custodyBefore)),
            aliceSigner,
            carolSigner
        );
        assertEq(v1.balanceOf(address(0xBEEF)), custodyBefore);

        // --- Rung 6: holders claim (relayer submits, beneficiary gets paid) ---------------
        uint256 aliceLeaf = 600_000e18;
        vm.prank(vm.addr(0xE1)); // relayer
        vault.claim(0, alice, aliceLeaf, TestMerkle.proofFor(_freshLeaves(), 0));
        assertEq(v2.balanceOf(alice), aliceLeaf);

        // --- Rung 7: verifySettlement reports honestly mid-window --------------------------
        (bool funded,,,, bool active,) = vault.verifySettlement();
        assertTrue(funded, "not funded");
        assertTrue(active, "not active");

        // --- Rung 8: residual sweep via multisig after all claims + expiry -----------------
        vm.prank(bob);
        vault.claim(1, bob, 400_000e18, TestMerkle.proofFor(_freshLeaves(), 1));
        vm.warp(block.timestamp + 180 days + 1);
        vm.prank(vm.addr(0xE2)); // anyone
        vault.expireClaims();
        v2.mint(address(vault), 123e18); // simulate over-funding dust
        _safeExec(abi.encodeCall(MigrationVault.sweepResidual, ()), bobSigner, carolSigner);
        assertEq(v2.balanceOf(address(safe)), 123e18);
    }

    /// A single signer cannot execute anything privileged through the Safe — the
    /// SUR-662 acceptance criterion (unauthorized/single-signer attempt cannot execute).
    function test_E2E_SingleSignerCannotAct() public {
        bytes memory data = abi.encodeCall(MigrationVault.activateClaims, ());
        vm.prank(aliceSigner);
        vm.expectRevert("MiniSafe: below threshold");
        MiniSafe(address(safe)).approveAndExecute(address(vault), data, _single(0));
    }

    /// Operator EOA cannot bypass the Safe while the Safe owns the vault.
    function test_E2E_DeployerEOALockedOut() public {
        vault.transferOwnership(address(safe));
        vm.prank(address(safe));
        vault.acceptOwnership();
        vm.prank(address(this));
        vm.expectRevert(MigrationVault.NotOwner.selector);
        vault.activateClaims();
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

    function _single(uint8 i) internal pure returns (uint8[] memory a) {
        a = new uint8[](1);
        a[0] = i;
    }

    function _safeExec(bytes memory data, address, address) internal {
        // threshold-2 execution: caller relays the two approvals' bitmap by index
        uint8[] memory who = new uint8[](2);
        who[0] = 0;
        who[1] = 1;
        MiniSafe(address(safe)).approveAndExecute(address(vault), data, who);
    }

    function _freshLeaves() internal view returns (bytes32[] memory) {
        bytes32[] memory l = new bytes32[](2);
        l[0] = keccak256(abi.encodePacked(uint256(0), alice, uint256(600_000e18)));
        l[1] = keccak256(abi.encodePacked(uint256(1), bob, uint256(400_000e18)));
        return l;
    }

    function _tree() internal view returns (bytes32[] memory, uint256) {
        return (_freshLeaves(), 600_000e18 + 400_000e18);
    }
}
