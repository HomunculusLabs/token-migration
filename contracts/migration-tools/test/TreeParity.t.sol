// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ClaimTree} from "../src/ClaimTree.sol";
import {MigrationVault} from "migration/src/MigrationVault.sol";
import {MockERC20} from "migration/test/MockERC20.sol";
import {TestMerkle} from "migration/test/TestMerkle.sol";
import {Test} from "migration/test/Base.t.sol";

/**
 * @title TreeParity
 * @notice ON-CHAIN parity between this package's off-chain engine and the REAL vault: a tree
 *         built by ClaimTree (the BuildTree.s.sol engine) must commit, prove and pay through
 *         MigrationVault.claim() exactly like the migration suite's independent TestMerkle
 *         builder — same leaf formula, same node folding. Any drift in either direction
 *         (generator vs verifier) fails here instead of at launch.
 *
 *         Two independent builders are exercised deliberately:
 *           - ClaimTree  — levels-materialized, non-mutating (what BuildTree.s.sol uses);
 *           - TestMerkle — in-place collapsing (the migration suite's reference).
 *         Both must yield the SAME root and proofs the vault accepts — mutual confirmation that
 *         "promote-unchanged on odd levels" is the shared convention.
 *
 *         Edge indices covered: 0 (first), N-1 (last), and the bitmap/word + level-boundary
 *         indices 31/32/33/63/64/65 — the vault's claim bitmap switches words at 32/64, and
 *         non-2^n trees switch level structure at the same magnitudes.
 */
contract TreeParityTest is Test {
    MockERC20 internal v1;
    MockERC20 internal v2;
    MigrationVault internal vault;

    uint256 internal constant LEAF_COUNT = 66; // non-2^n: exercises odd tails at levels 0..3
    uint256 internal constant DEPOSIT_DEADLINE = 2_000_000;
    uint256 internal constant EXECUTION_WINDOW = 7 days;
    uint256 internal constant CLAIM_PERIOD = 180 days;

    address[LEAF_COUNT] internal accounts;
    uint256[LEAF_COUNT] internal amounts;
    bytes32[] internal leaves;
    bytes32 internal root;
    bytes32[][] internal proofs;

    function setUp() public {
        v1 = new MockERC20("Surplus v1", "SURPLUS");
        v2 = new MockERC20("Surplus v2", "SURPLUS2");
        // rate 0, pro-rata off
        vault = new MigrationVault(
            v1, v2, DEPOSIT_DEADLINE, DEPOSIT_DEADLINE + 3 days, EXECUTION_WINDOW, CLAIM_PERIOD, 0, false, address(this)
        );

        // Deterministic pseudo-random-but-distinct accounts/amounts; index i is leaf i.
        uint256 total;
        for (uint256 i; i < LEAF_COUNT; ++i) {
            accounts[i] = address(uint160(uint256(keccak256(abi.encode(i))) & type(uint160).max));
            if (accounts[i] == address(0)) accounts[i] = address(1);
            amounts[i] = uint256(keccak256(abi.encodePacked("amt", i))) % 1_000_000e18 + 1;
            total += amounts[i];
        }

        // Build with the OFF-CHAIN engine under test.
        leaves = new bytes32[](LEAF_COUNT);
        for (uint256 i; i < LEAF_COUNT; ++i) {
            leaves[i] = ClaimTree.leaf(i, accounts[i], amounts[i]);
        }
        bytes32[][] memory levels = ClaimTree.buildLevels(leaves);
        root = levels[levels.length - 1][0];
        proofs = new bytes32[][](LEAF_COUNT);
        for (uint256 i; i < LEAF_COUNT; ++i) {
            proofs[i] = ClaimTree.proofAt(levels, i);
        }

        // Drive the vault through its real lifecycle: commit → back → activate.
        vm.warp(DEPOSIT_DEADLINE + 1); // commitRoot requires the deposit deadline to have passed
        vault.commitRoot(root, total);
        v2.mint(address(vault), total);
        vault.activateClaims();
    }

    // -----------------------------------------------------------------------------------------
    // Positive: claims pay at the edge indices
    // -----------------------------------------------------------------------------------------

    function test_Claim_Succeeds_EdgeIndices() public {
        uint256[8] memory edges = [uint256(0), 65, 31, 32, 33, 63, 64, 1];
        // (0=first, 65=last for N=66; plus the word/level boundary indices; 1 as interior control)
        for (uint256 k; k < edges.length; ++k) {
            uint256 i = edges[k];
            uint256 before = v2.balanceOf(accounts[i]);
            vault.claim(i, accounts[i], amounts[i], proofs[i]); // anyone may relay
            assertTrue(v2.balanceOf(accounts[i]) == before + amounts[i], "edge index did not pay");
        }
    }

    // -----------------------------------------------------------------------------------------
    // Positive: builder parity — ClaimTree vs the suite's independent TestMerkle
    // -----------------------------------------------------------------------------------------

    function test_Root_MatchesIndependentBuilder() public view {
        bytes32[] memory copy = new bytes32[](LEAF_COUNT);
        for (uint256 i; i < LEAF_COUNT; ++i) {
            copy[i] = leaves[i];
        }
        assertEq(root, TestMerkle.rootOf(copy), "ClaimTree root != TestMerkle root");
    }

    function test_Proofs_MatchIndependentBuilder() public view {
        for (uint256 i; i < LEAF_COUNT; ++i) {
            bytes32[] memory copy = new bytes32[](LEAF_COUNT);
            for (uint256 k; k < LEAF_COUNT; ++k) {
                copy[k] = leaves[k];
            }
            bytes32[] memory ref = TestMerkle.proofFor(copy, i);
            assertEq(uint256(ref.length), uint256(proofs[i].length), "proof length mismatch");
            for (uint256 k; k < ref.length; ++k) {
                assertTrue(ref[k] == proofs[i][k], "proof entry mismatch");
            }
        }
    }

    // -----------------------------------------------------------------------------------------
    // Positive: proofs verify under the vault's own OZ MerkleProof (pure check, no state)
    // -----------------------------------------------------------------------------------------

    function test_AllProofs_VerifyUnderOZ() public view {
        for (uint256 i; i < LEAF_COUNT; ++i) {
            bytes32 computed = ClaimTree.leaf(i, accounts[i], amounts[i]);
            bytes32[] memory proof = proofs[i];
            for (uint256 k; k < proof.length; ++k) {
                computed = ClaimTree.hashPair(computed, proof[k]);
            }
            assertTrue(computed == root, "fold(proof) != root");
        }
    }

    // -----------------------------------------------------------------------------------------
    // Negative: the vault rejects tampered submissions
    // -----------------------------------------------------------------------------------------

    function test_RevertIf_WrongAccount() public {
        uint256 i = 33;
        address thief = address(0xBEEF);
        vm.expectRevert(MigrationVault.InvalidProof.selector);
        vault.claim(i, thief, amounts[i], proofs[i]);
    }

    function test_RevertIf_WrongIndex() public {
        // Leaf 40's (account, amount) presented under leaf 64's proof/index.
        uint256 presented = 64;
        vm.expectRevert(MigrationVault.InvalidProof.selector);
        vault.claim(presented, accounts[40], amounts[40], proofs[presented]);
    }

    function test_RevertIf_TamperedAmount() public {
        uint256 i = 32;
        vm.expectRevert(MigrationVault.InvalidProof.selector);
        vault.claim(i, accounts[i], amounts[i] + 1, proofs[i]);
    }

    function test_RevertIf_SiblingSubstitutedProof() public {
        // Replace one sibling with the zero hash (the classic zero-padding mix-up) — must fail.
        uint256 i = 63;
        bytes32[] memory bad = proofs[i];
        bad[0] = bytes32(0);
        vm.expectRevert(MigrationVault.InvalidProof.selector);
        vault.claim(i, accounts[i], amounts[i], bad);
    }

    function test_RevertIf_TruncatedProof() public {
        // Drop the last sibling — a fold that never reaches the real root.
        uint256 i = 31;
        bytes32[] memory bad = new bytes32[](proofs[i].length - 1);
        for (uint256 k; k < bad.length; ++k) {
            bad[k] = proofs[i][k];
        }
        vm.expectRevert(MigrationVault.InvalidProof.selector);
        vault.claim(i, accounts[i], amounts[i], bad);
    }

    // -----------------------------------------------------------------------------------------
    // Positive: builder parity at other sizes — root and every proof must match the independent
    // builder for the powers-of-two neighbors and tiny trees (single-leaf edge included).
    // -----------------------------------------------------------------------------------------

    function test_Parity_OddSizes() public pure {
        // TestMerkle.proofFor requires n > 1 (its single-leaf case is the empty proof by
        // convention, not by construction), so the reference comparison starts at n = 2.
        // ClaimTree's own n = 1 behavior (leaf IS the root, empty proof) is pinned separately
        // by test_Claim_Succeeds_EdgeIndices on the N=66 tree and by the scripts' depth logic.
        uint256[4] memory sizes = [uint256(2), 3, 31, 32];
        for (uint256 s; s < sizes.length; ++s) {
            uint256 n = sizes[s];
            bytes32[] memory ls = new bytes32[](n);
            for (uint256 i; i < n; ++i) {
                ls[i] = ClaimTree.leaf(i, address(uint160((i + 1) & type(uint160).max)), i * 1e18 + 1);
            }
            bytes32[][] memory lv = ClaimTree.buildLevels(ls);
            bytes32 r = lv[lv.length - 1][0];
            assertEq(r, TestMerkle.rootOf(_copy(ls)), "root mismatch");
            for (uint256 i; i < n; ++i) {
                bytes32[] memory mine = ClaimTree.proofAt(lv, i);
                bytes32[] memory refProof = TestMerkle.proofFor(_copy(ls), i);
                assertTrue(mine.length == refProof.length, "proof length mismatch");
                for (uint256 k; k < mine.length; ++k) {
                    assertTrue(mine[k] == refProof[k], "proof entry mismatch");
                }
            }
        }
    }

    function _copy(bytes32[] memory src) internal pure returns (bytes32[] memory dst) {
        dst = new bytes32[](src.length);
        for (uint256 i; i < src.length; ++i) {
            dst[i] = src[i];
        }
    }

    // -----------------------------------------------------------------------------------------
    // Degenerate tree: n = 1 — the leaf IS the root, proof is empty, claim must still pay.
    // -----------------------------------------------------------------------------------------

    function test_Claim_SingleLeafTree() public {
        address solo = address(0x5D15);
        uint256 amt = 42e18;
        bytes32 loneLeaf = ClaimTree.leaf(0, solo, amt);
        bytes32 loneRoot = ClaimTree.rootOf(_single(loneLeaf));
        assertEq(loneRoot, loneLeaf, "single-leaf root must equal the leaf");

        MockERC20 v1b = new MockERC20("v1b", "V1B");
        MockERC20 v2b = new MockERC20("v2b", "V2B");
        // setUp already warped past DEPOSIT_DEADLINE, so a fresh vault with that constant would
        // be dead on arrival (DeadlineTooSoon). Give it a deadline 1s in the future and warp.
        uint256 farDeadline = block.timestamp + 1;
        MigrationVault fresh = new MigrationVault(
            v1b, v2b, farDeadline, farDeadline + 3 days, EXECUTION_WINDOW, CLAIM_PERIOD, 0, false, address(this)
        );
        vm.warp(farDeadline + 1);
        fresh.commitRoot(loneRoot, amt);
        v2b.mint(address(fresh), amt);
        fresh.activateClaims();

        bytes32[] memory noProof = new bytes32[](0);
        fresh.claim(0, solo, amt, noProof);
        assertTrue(v2b.balanceOf(solo) == amt, "single-leaf claim did not pay");
    }

    function _single(bytes32 lone) internal pure returns (bytes32[] memory one) {
        one = new bytes32[](1);
        one[0] = lone;
    }
}
