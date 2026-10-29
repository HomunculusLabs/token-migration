// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @dev A tiny Merkle helper for the migration suites. Mirrors the Uniswap reference distributor's
 *      conventions so tests exercise the EXACT leaf/proof format the vault verifies:
 *
 *        leaf(i)  = keccak256(abi.encodePacked(index, account, amount))
 *        node     = keccak256(concat(left, right))   — sorted, like OZ's library
 *        odd tail = promoted unchanged to the next level
 *
 *      The sorted-pair node hash matches OpenZeppelin's `MerkleProof.verify` (which the vault uses);
 *      the LEAF format is the vault's own (Uniswap single-hash), and that combination is precisely
 *      what the off-chain generator must reproduce. Building it here, independently of the
 *      generator, is what makes a proof-format drift a test failure instead of a launch incident.
 */
library TestMerkle {
    function leaf(uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(index, account, amount));
    }

    function hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(bytes.concat(a, b)) : keccak256(bytes.concat(b, a));
    }

    function rootOf(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "empty");
        while (leaves.length > 1) {
            uint256 n = (leaves.length + 1) / 2;
            for (uint256 i = 0; i < n; ++i) {
                leaves[i] = i * 2 + 1 < leaves.length ? hashPair(leaves[i * 2], leaves[i * 2 + 1]) : leaves[i * 2];
            }
            // solhint-disable-next-line no-inline-assembly
            assembly {
                mstore(leaves, n)
            }
        }
        return leaves[0];
    }

    /// @dev COLLAPSES `leaves` IN PLACE while walking levels; pass a fresh copy when both root and
    ///      proof are needed. Single-leaf trees return an empty proof (the leaf IS the root).
    function proofFor(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory proof) {
        require(leaves.length > 1, "single-leaf tree has empty proof");
        proof = new bytes32[](depth(leaves.length));
        uint256 pos;
        while (leaves.length > 1) {
            uint256 sibling = index ^ 1;
            if (sibling < leaves.length) proof[pos++] = leaves[sibling];
            uint256 n = (leaves.length + 1) / 2;
            for (uint256 i = 0; i < n; ++i) {
                leaves[i] = i * 2 + 1 < leaves.length ? hashPair(leaves[i * 2], leaves[i * 2 + 1]) : leaves[i * 2];
            }
            // solhint-disable-next-line no-inline-assembly
            assembly {
                mstore(leaves, n)
            }
            index >>= 1;
        }
        // trim to actual length
        // solhint-disable-next-line no-inline-assembly
        assembly {
            mstore(proof, pos)
        }
    }

    function depth(uint256 n) internal pure returns (uint256 d) {
        while (n > 1) {
            n = (n + 1) / 2;
            ++d;
        }
    }
}
