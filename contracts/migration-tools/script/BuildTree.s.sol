// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ClaimTree} from "../src/ClaimTree.sol";
import {TreeIO} from "./TreeIO.sol";

/**
 * @title BuildTree
 * @notice deposits.csv → {tree.json, tree.csv}: the deployable, independently rebuildable claim
 *         tree for MigrationVault.commitRoot. Runs with NO RPC and NO broadcast — pure local
 *         computation (nothing to sign, nothing leaves the machine).
 *
 *         INPUT  input/deposits.csv — columns `account,amount` (amount in RAW WEI, one header
 *                line; '#' comment lines welcome). Row order is PRESERVED and becomes the leaf
 *                index (0-based): index is the vault's global uniqueness domain, so a stable
 *                input ordering is what makes independent rebuilds byte-identical.
 *         OUTPUT output/tree.json — {root,total,leafCount,leaves:[{index,account,amount,proof[]}]}
 *                (one leaf per line)
 *                output/tree.csv  — index,account,amount (the publication file)
 *
 * @dev    Failure is LOUD: any malformed row (bad address, bad amount, zero amount, duplicate
 *         account) reverts the whole script — a half-parsed deposit list must never reach a root.
 *         Duplicate detection uses open addressing over a power-of-two memory table (migration
 *         scale is ≪ table size, so chains are short; the table is allocated once per run).
 *
 *         Output is streamed a line at a time. EVM memory is never freed, so assembling the
 *         document with repeated string.concat costs memory quadratic in the leaf count and runs
 *         out at real holder counts (thousands of leaves).
 */
contract BuildTree is TreeIO {
    /// @dev Open-addressing table for duplicate-account detection (see _insert).
    uint256 private constant _TABLE_SIZE = 1 << 16;

    address[_TABLE_SIZE] private _dupTable;

    function run() public {
        (address[] memory accounts, uint256[] memory amounts, bytes32[] memory leaves, uint256 total) = _parse();

        // Pass 2: levels + root + proofs.
        bytes32[][] memory levels = ClaimTree.buildLevels(leaves);
        bytes32 root = levels[levels.length - 1][0];
        _write(root, total, accounts, amounts, levels);

        _log(string.concat("root      = ", vm.toString(root)));
        _log(string.concat("total     = ", vm.toString(total), " (raw wei)"));
        _log(string.concat("leafCount = ", vm.toString(accounts.length)));
        _log("wrote output/tree.json + output/tree.csv");
    }

    /// @dev Pass 1: parse + validate + dedup-check.
    function _parse()
        private
        returns (address[] memory accounts, uint256[] memory amounts, bytes32[] memory leaves, uint256 total)
    {
        string[] memory lines = _readCsvLines("input/deposits.csv");
        if (lines.length == 0) revert("BuildTree: no data rows in input/deposits.csv");
        _expectHeader(lines[0], "account", "amount");

        uint256 n = lines.length - 1;
        leaves = new bytes32[](n);
        accounts = new address[](n);
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            (address account, uint256 amount) = _parseDeposit(lines[i + 1], i);
            _insert(account, i);
            leaves[i] = ClaimTree.leaf(i, account, amount);
            accounts[i] = account;
            amounts[i] = amount;
            total += amount;
        }
    }

    /// @dev Pass 3: serialize. Hand-rolled so the exact schema is visible in one place.
    function _write(
        bytes32 root,
        uint256 total,
        address[] memory accounts,
        uint256[] memory amounts,
        bytes32[][] memory levels
    ) private {
        // The output dir is task-local state, not repo content; keep it in .gitignore and create
        // it on demand so a fresh checkout never fails on a missing directory.
        vm.createDir("output", true);
        string memory jsonPath = "output/tree.json";
        string memory csvPath = "output/tree.csv";
        // writeLine appends, so a previous run's files must go first.
        if (vm.isFile(jsonPath)) vm.removeFile(jsonPath);
        if (vm.isFile(csvPath)) vm.removeFile(csvPath);

        uint256 n = accounts.length;
        vm.writeLine(jsonPath, "{");
        vm.writeLine(jsonPath, string.concat('  "root": "', vm.toString(root), '",'));
        vm.writeLine(jsonPath, string.concat('  "total": "', vm.toString(total), '",'));
        vm.writeLine(jsonPath, string.concat('  "leafCount": ', vm.toString(n), ","));
        vm.writeLine(jsonPath, '  "leaves": [');
        vm.writeLine(csvPath, "index,account,amount");
        for (uint256 i; i < n; ++i) {
            _writeLeaf(jsonPath, csvPath, i, accounts[i], amounts[i], ClaimTree.proofAt(levels, i), i + 1 == n);
        }
        vm.writeLine(jsonPath, "  ]");
        vm.writeLine(jsonPath, "}");
    }

    /// @dev One leaf: its JSON line (comma unless last) and its publication-CSV row.
    function _writeLeaf(
        string memory jsonPath,
        string memory csvPath,
        uint256 i,
        address account,
        uint256 amount,
        bytes32[] memory proof,
        bool last
    ) private {
        string memory idx = vm.toString(i);
        string memory acct = vm.toString(account);
        string memory amt = vm.toString(amount);
        vm.writeLine(
            jsonPath,
            string.concat(
                '    {"index":',
                idx,
                ',"account":"',
                acct,
                '","amount":"',
                amt,
                '","proof":',
                _proofJson(proof),
                last ? "}" : "},"
            )
        );
        vm.writeLine(csvPath, string.concat(idx, ",", acct, ",", amt));
    }

    /// @dev `["0x…","0x…"]` (lowercase hex, as vm.toString(bytes32) prints) in one exact-size buffer.
    function _proofJson(bytes32[] memory proof) private pure returns (string memory) {
        uint256 len = proof.length;
        if (len == 0) return "[]";
        bytes memory out = new bytes(2 + len * 68 + (len - 1));
        bytes16 hexChars = "0123456789abcdef";
        uint256 p;
        out[p++] = "[";
        for (uint256 k; k < len; ++k) {
            if (k != 0) out[p++] = ",";
            out[p++] = '"';
            out[p++] = "0";
            out[p++] = "x";
            bytes32 word = proof[k];
            for (uint256 b; b < 32; ++b) {
                uint8 v = uint8(word[b]);
                out[p++] = hexChars[v >> 4];
                out[p++] = hexChars[v & 0x0f];
            }
            out[p++] = '"';
        }
        out[p] = "]";
        return string(out);
    }

    // -----------------------------------------------------------------------------------------
    // Duplicate detection: open addressing, power-of-two table. Never full by construction
    // (input size ≪ 65,536 at migration scale; guard reverts loudly if that assumption breaks).
    // -----------------------------------------------------------------------------------------

    error DuplicateAccount(address account, uint256 row);
    error TableFull();

    function _insert(address a, uint256 row) private {
        uint256 mask = _TABLE_SIZE - 1;
        uint256 slot = uint256(keccak256(abi.encodePacked(a))) & mask;
        for (uint256 probe; probe < _TABLE_SIZE; ++probe) {
            address existing = _dupTable[slot];
            if (existing == address(0)) {
                if (a == address(0)) revert MalformedRow(row, "", "address 0 not allowed");
                _dupTable[slot] = a;
                return;
            }
            if (existing == a) revert DuplicateAccount(a, row);
            slot = (slot + 1) & mask;
        }
        revert TableFull();
    }
}
