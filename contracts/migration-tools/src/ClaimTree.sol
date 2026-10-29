// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ClaimTree
 * @notice The off-chain claim-tree engine for the SURPLUS v1 → v2 migration — the "tree build
 *         tooling" DESIGN.md §9 defers to this package (contracts/migration/DESIGN.md).
 *
 *         THE ORDERING RULE OF THIS FILE: the leaf hash is MIRRORED, never re-invented. The
 *         canonical definition lives in `contracts/migration/src/MigrationVault.sol`:
 *
 *             _verifyLeaf:  bytes32 leaf = keccak256(abi.encodePacked(index, account, amount));
 *
 *         — the Uniswap reference distributor format (DESIGN.md §4), explicitly NOT OZ's
 *         StandardMerkleTree double-hash `keccak256(bytes.concat(keccak256(abi.encode(a,b))))`.
 *         If the vault ever changes, this mirror changes with it, and the parity suite
 *         (test/TreeParity.t.sol, which drives the REAL vault) is what makes silent drift a
 *         test failure instead of a launch incident.
 *
 * @dev  Node hashing mirrors what the vendored verifier ACTUALLY does — read directly from the
 *       workspace's npm-pinned OpenZeppelin 4.9.6
 *       (node_modules openzeppelin/contracts/utils/cryptography/MerkleProof.sol):
 *
 *             _hashPair(a, b)  = a < b ? keccak256(concat(a, b)) : keccak256(concat(b, a))
 *             processProof     = fold _hashPair(computed, proof[i]) over exactly proof.length items
 *
 *       Verified properties of that source (v4.9.2 file text, npm package 4.9.6): single keccak
 *       per node, operands SORTED with NO deduplication (an equal pair hashes as H(a,a)), and no
 *       notion of padding — the verifier folds exactly the sibling branch it is handed, so any
 *       builder convention that emits self-consistent siblings verifies. Two canonical
 *       conventions exist for ODD levels; they produce DIFFERENT roots and must not be mixed:
 *         - promote-unchanged (the Uniswap reference distributor, and this repo's
 *           contracts/migration/test/TestMerkle.sol, already proven against the vault on-chain
 *           by the migration suite): the lone tail node moves up a level as-is and contributes
 *           NO sibling to any proof;
 *         - zero-pad-and-emit (OZ's JavaScript merkle-tree library): the missing sibling is a
 *           zero-hash constant that must then appear in every crossing proof.
 *       This engine PROMOTES (never pads), because (a) it matches the vault's existing,
 *       on-chain-proven reference builder byte-for-byte, and (b) proofs stay minimal. The
 *       parity suite re-proves the choice against the REAL vault at boundary indices.
 *       Consequences honored below:
 *         - sibling order in a proof is irrelevant (the verifier re-sorts each fold);
 *         - proof length for leaf i = number of levels in which i's subtree has a real
 *           sibling — short proofs are valid, `processProof` folds what it gets;
 *         - single-leaf tree: the leaf IS the root and every proof is empty.
 *
 *       None of these functions mutate their inputs, so root + all proofs can be derived from
 *       one leaf array. Total cost is O(n·log n) (levels are materialized once, then each proof
 *       is a walk up them), which is what makes a full migration-scale CSV tractable on one run.
 */
library ClaimTree {
    // -----------------------------------------------------------------------------------------
    // Leaf — the EXACT vault leaf. Mirror of MigrationVault._verifyLeaf. Do not "fix" it.
    // -----------------------------------------------------------------------------------------

    function leaf(uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(index, account, amount));
    }

    // -----------------------------------------------------------------------------------------
    // Node — mirror of OZ 4.9.6 MerkleProof._hashPair (sorted pair; equal operands kept).
    // -----------------------------------------------------------------------------------------

    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(bytes.concat(a, b)) : keccak256(bytes.concat(b, a));
    }

    // -----------------------------------------------------------------------------------------
    // Tree
    // -----------------------------------------------------------------------------------------

    /// @notice Materialize every level bottom-up. `levels[0]` is the leaf array (taken as-is,
    ///         not copied and not modified); `levels[k][i]` over `levels[k+1][j]` where the odd
    ///         tail, if any, is promoted unchanged.
    function buildLevels(bytes32[] memory leaves) internal pure returns (bytes32[][] memory levels) {
        uint256 n = leaves.length;
        require(n > 0, "ClaimTree: empty");
        levels = new bytes32[][](depth(n) + 1);
        levels[0] = leaves;
        for (uint256 k = 0; k + 1 < levels.length; ++k) {
            bytes32[] memory cur = levels[k];
            bytes32[] memory next = new bytes32[]((cur.length + 1) / 2);
            for (uint256 i; i < next.length; ++i) {
                uint256 j = i * 2;
                next[i] = j + 1 < cur.length ? hashPair(cur[j], cur[j + 1]) : cur[j];
            }
            levels[k + 1] = next;
        }
    }

    /// @notice Root over `leaves` in their GIVEN order (index = array position — the vault's
    ///         global uniqueness domain).
    function rootOf(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[][] memory levels = buildLevels(leaves);
        return levels[levels.length - 1][0];
    }

    /// @notice Sibling branch for `index`, walking the materialized levels upward. Proof entries
    ///         are only emitted for levels where the sibling REALLY EXISTS (odd tails none).
    function proofAt(bytes32[][] memory levels, uint256 index) internal pure returns (bytes32[] memory proof) {
        require(index < levels[0].length, "ClaimTree: index out of range");
        proof = new bytes32[](levels.length - 1); // upper bound = depth; trimmed below
        uint256 pos;
        uint256 at = index;
        for (uint256 k; k + 1 < levels.length; ++k) {
            uint256 sibling = at ^ 1;
            if (sibling < levels[k].length) {
                proof[pos++] = levels[k][sibling];
            }
            at >>= 1;
        }
        assembly ("memory-safe") {
            mstore(proof, pos)
        }
    }

    /// @notice Convenience single-shot: proof for `index` over `leaves`.
    function proofFor(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory) {
        return proofAt(buildLevels(leaves), index);
    }

    /// @notice Levels with at least one real pairing (max proof length for n leaves).
    function depth(uint256 n) internal pure returns (uint256 d) {
        while (n > 1) {
            n = (n + 1) / 2;
            ++d;
        }
    }
}
