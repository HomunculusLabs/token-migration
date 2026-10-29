// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ClaimTree} from "../src/ClaimTree.sol";
import {TreeIO} from "./TreeIO.sol";

/**
 * @title VerifyTree
 * @notice Independent local check of output/tree.json — the "re-verify before you commitRoot"
 *         half of the dossier §04 review process (independent rebuilds, published files).
 *
 *         With no input/claims.csv present, it verifies THE WHOLE FILE:
 *           1. re-hashes every leaf with the vault's EXACT leaf formula,
 *           2. re-computes the root from those leaves and compares with the file's root,
 *           3. re-derives every proof from the leaves and compares with the file's proofs,
 *           4. checks Σ amounts == total.
 *
 *         With input/claims.csv present (lines `index,account,amount`, header included), it
 *         ADDITIONALLY verifies each listed entry by folding its STORED proof (vault-style,
 *         sorted pairs) back to the root — the published-artifact view: what a third party
 *         without the engine would check.
 *
 *         NO RPC, NO fork, NO broadcast — pure keccak. Any failure reverts (forge script exits
 *         non-zero); success prints a per-mode summary.
 *
 * @dev    The leaves array is decoded ONCE. Asking the JSON parser for each field of each leaf
 *         re-parses the whole multi-megabyte file every time, which is quadratic in the leaf
 *         count (minutes at real holder counts).
 */
contract VerifyTree is TreeIO {
    struct Leaf {
        uint256 index;
        address account;
        uint256 amount;
        bytes32[] proof;
    }

    string private constant _LEAF_TYPE = "Leaf(uint256 index,address account,uint256 amount,bytes32[] proof)";

    error RootMismatch(bytes32 fromLeaves, bytes32 inFile);
    error TotalMismatch(uint256 fromLeaves, uint256 inFile);
    error IndexMismatch(uint256 expected, uint256 inFile); // array position IS the leaf index
    error IndexOutOfRange(uint256 index, uint256 leafCount);
    error LeafMismatch(uint256 index, address account, uint256 amount);
    error LeafCountMismatch(uint256 decoded, uint256 inFile);
    error ProofLengthMismatch(uint256 index, uint256 expected, uint256 actual);
    error ProofEntryMismatch(uint256 index, uint256 position, bytes32 expected, bytes32 actual);
    error ClaimFailed(uint256 index, address account, uint256 amount);

    function run() public {
        string memory json = vm.readFile("output/tree.json");

        // root/total are JSON strings ("0x…"/decimal) by schema; leafCount is a JSON number.
        bytes32 rootInFile = vm.parseBytes32(vm.parseJsonString(json, ".root"));
        uint256 totalInFile = vm.parseUint(vm.parseJsonString(json, ".total"));
        uint256 leafCount = vm.parseUint(vm.parseJsonString(json, ".leafCount"));
        Leaf[] memory leaves = abi.decode(vm.parseJsonTypeArray(json, ".leaves", _LEAF_TYPE), (Leaf[]));
        if (leaves.length != leafCount) revert LeafCountMismatch(leaves.length, leafCount);

        // Independent rebuild: leaf hashes → levels → root, all via the ClaimTree mirror of the
        // vault's formulas. If BuildTree and this disagree, one of them drifted from the vault.
        bytes32[] memory hashes = new bytes32[](leafCount);
        uint256 total;
        for (uint256 i; i < leafCount; ++i) {
            if (leaves[i].index != i) revert IndexMismatch(i, leaves[i].index);
            hashes[i] = ClaimTree.leaf(i, leaves[i].account, leaves[i].amount);
            total += leaves[i].amount;
        }
        bytes32[][] memory levels = ClaimTree.buildLevels(hashes);
        bytes32 root = levels[levels.length - 1][0];

        if (root != rootInFile) revert RootMismatch(root, rootInFile);
        if (total != totalInFile) revert TotalMismatch(total, totalInFile);

        uint256 claimsChecked;
        bool hasClaims = vm.isFile("input/claims.csv");
        if (hasClaims) {
            claimsChecked = _verifyClaims(leaves, root);
        }

        // Whole-file proof re-derivation always runs (even in claims mode) — the stored proofs
        // are the artifact actually published, so they are what gets re-derived and compared.
        _verifyProofs(leaves, levels);

        _log(string.concat("root      = ", vm.toString(root)));
        _log(string.concat("leafCount = ", vm.toString(leafCount), " (all proofs re-derived + matched)"));
        if (hasClaims) {
            _log(string.concat("claims    = ", vm.toString(claimsChecked), " folded to root OK"));
        }
        _log("OK: tree verification passed");
    }

    /// @dev Re-derive every proof from the leaves; compare with the stored branch entry-wise.
    function _verifyProofs(Leaf[] memory leaves, bytes32[][] memory levels) private pure {
        for (uint256 i; i < leaves.length; ++i) {
            bytes32[] memory expect = ClaimTree.proofAt(levels, i);
            bytes32[] memory got = leaves[i].proof;
            if (got.length != expect.length) revert ProofLengthMismatch(i, expect.length, got.length);
            for (uint256 k; k < expect.length; ++k) {
                if (got[k] != expect[k]) revert ProofEntryMismatch(i, k, expect[k], got[k]);
            }
        }
    }

    /// @dev Each `index,account,amount` line must match the leaf at that index, and its STORED
    ///      proof must fold back to the root using the vault's exact node hash.
    function _verifyClaims(Leaf[] memory leaves, bytes32 root) private view returns (uint256 checked) {
        string[] memory lines = _readCsvLines("input/claims.csv");
        if (lines.length == 0) revert("VerifyTree: no data rows in input/claims.csv");
        _expectHeader(lines[0], "index", "account");
        for (uint256 r; r < lines.length - 1; ++r) {
            (uint256 index, address account, uint256 amount) = _parseClaim(lines[r + 1], r);
            if (index >= leaves.length) revert IndexOutOfRange(index, leaves.length);
            if (account != leaves[index].account || amount != leaves[index].amount) {
                revert LeafMismatch(index, account, amount);
            }
            bytes32 computed = ClaimTree.leaf(index, account, amount);
            bytes32[] memory proof = leaves[index].proof;
            for (uint256 k; k < proof.length; ++k) {
                computed = ClaimTree.hashPair(computed, proof[k]);
            }
            if (computed != root) revert ClaimFailed(index, account, amount);
            ++checked;
        }
    }
}
