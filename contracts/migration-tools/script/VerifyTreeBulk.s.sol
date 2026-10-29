// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ClaimTree} from "../src/ClaimTree.sol";
import {TreeIO} from "./TreeIO.sol";

interface BulkVm {
    function parseJsonTypeArray(string calldata json, string calldata key, string calldata typeDescription)
        external
        pure
        returns (bytes memory);
}

/**
 * @title VerifyTreeBulk
 * @notice The second of the kit's three tree checks. It runs the same whole-file checks as VerifyTree (re-hash
 *         every leaf with the vault's formula, rebuild the root, re-derive every stored proof, Σ amounts ==
 *         total) and adds what a claimant's wallet does: fold every STORED proof back to the root with the
 *         vault's node hash.
 * @dev    Decodes the leaves array once; a per-field parse re-reads the whole file each time.
 */
contract VerifyTreeBulk is TreeIO {
    BulkVm internal constant bvm = BulkVm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    struct Leaf {
        uint256 index;
        address account;
        uint256 amount;
        bytes32[] proof;
    }

    error RootMismatch(bytes32 fromLeaves, bytes32 inFile);
    error TotalMismatch(uint256 fromLeaves, uint256 inFile);
    error IndexMismatch(uint256 expected, uint256 inFile);
    error CountMismatch(uint256 decoded, uint256 inFile);
    error ProofMismatch(uint256 index);
    error FoldFailed(uint256 index);

    function run() public {
        string memory json = vm.readFile("output/tree.json");
        bytes32 rootInFile = vm.parseBytes32(vm.parseJsonString(json, ".root"));
        uint256 totalInFile = vm.parseUint(vm.parseJsonString(json, ".total"));
        uint256 leafCount = vm.parseUint(vm.parseJsonString(json, ".leafCount"));
        Leaf[] memory leaves = abi.decode(
            bvm.parseJsonTypeArray(
                json, ".leaves", "Leaf(uint256 index,address account,uint256 amount,bytes32[] proof)"
            ),
            (Leaf[])
        );
        if (leaves.length != leafCount) revert CountMismatch(leaves.length, leafCount);

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

        for (uint256 i; i < leafCount; ++i) {
            bytes32[] memory expect = ClaimTree.proofAt(levels, i);
            bytes32[] memory got = leaves[i].proof;
            if (got.length != expect.length) revert ProofMismatch(i);
            bytes32 folded = hashes[i];
            for (uint256 k; k < got.length; ++k) {
                if (got[k] != expect[k]) revert ProofMismatch(i);
                folded = ClaimTree.hashPair(folded, got[k]);
            }
            if (folded != root) revert FoldFailed(i);
        }
        _log(string.concat("root      = ", vm.toString(root)));
        _log(string.concat("leafCount = ", vm.toString(leafCount), " (all proofs re-derived, matched, folded to root)"));
        _log(string.concat("total     = ", vm.toString(total)));
        _log("OK: bulk tree verification passed");
    }
}
