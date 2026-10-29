// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @dev Shared plumbing for the migration-tools scripts: a MINIMAL Vm surface (same stance as
 *      contracts/migration/test/Base.t.sol — no forge-std vendoring in this monorepo) plus the
 *      CSV/string helpers both scripts need. All file access is bounded by foundry.toml's
 *      fs_permissions (read ./input, read-write ./output); scripts never touch anything else
 *      and never broadcast.
 */
interface ScriptVm {
    function readFile(string calldata path) external view returns (string memory);
    function isFile(string calldata path) external returns (bool);
    function createDir(string calldata path, bool recursive) external;
    function writeFile(string calldata path, string calldata data) external;
    function parseAddress(string calldata stringifiedValue) external pure returns (address);
    function parseUint(string calldata stringifiedValue) external pure returns (uint256);
    function parseBytes32(string calldata stringifiedValue) external pure returns (bytes32);
    function parseJsonString(string calldata json, string calldata key) external view returns (string memory);
    function parseJsonAddress(string calldata json, string calldata key) external view returns (address);
    function parseJsonBytes32Array(string calldata json, string calldata key) external view returns (bytes32[] memory);
    function parseJsonTypeArray(string calldata json, string calldata key, string calldata typeDescription)
        external
        pure
        returns (bytes memory);
    function writeLine(string calldata path, string calldata data) external;
    function removeFile(string calldata path) external;
    function toString(uint256 value) external pure returns (string memory);
    function toString(address value) external pure returns (string memory);
    function toString(bytes32 value) external pure returns (string memory);
}

contract TreeIO {
    ScriptVm internal constant vm = ScriptVm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    /// @dev Script stdout: this forge build's script runner has no console-address code and no
    ///      string cheatcode, so run summaries are EVENTS — forge decodes them in the trace.
    event Log(string message);

    function _log(string memory message) internal {
        emit Log(message);
    }
    error BadHeader(string line, string expectedPrefix);
    error MalformedRow(uint256 row, string line, string reason);

    // -----------------------------------------------------------------------------------------
    // CSV reading
    // -----------------------------------------------------------------------------------------

    /**
     * @dev All MEANINGFUL lines of a CSV: splits on '\n' (tolerating '\r\n'), drops blank lines
     *      and '#'-comment lines. Line numbering in errors is the ORDINAL of the returned array
     *      (header = row 0), not the physical file line — deterministic either way.
     */
    function _readCsvLines(string memory path) internal view returns (string[] memory lines) {
        bytes memory c = bytes(vm.readFile(path));
        uint256 cap = 64;
        string[] memory out = new string[](cap);
        uint256 n;
        uint256 start;
        for (uint256 i; i <= c.length; ++i) {
            if (i != c.length && c[i] != 0x0a) continue;
            uint256 end = i;
            if (end > start && c[end - 1] == 0x0d) --end; // strip '\r'
            if (_meaningful(c, start, end)) {
                if (n == cap) {
                    string[] memory bigger = new string[](cap * 2);
                    for (uint256 k; k < cap; ++k) {
                        bigger[k] = out[k];
                    }
                    out = bigger;
                    cap *= 2;
                }
                out[n++] = _slice(c, start, end);
            }
            start = i + 1;
        }
        lines = new string[](n);
        for (uint256 k; k < n; ++k) {
            lines[k] = out[k];
        }
    }

    /// @dev Non-blank after trim, and not a '#' comment (leading spaces before '#' allowed).
    function _meaningful(bytes memory c, uint256 start, uint256 end) private pure returns (bool) {
        while (start < end && (c[start] == 0x20 || c[start] == 0x09)) {
            ++start;
        }
        return start < end && c[start] != 0x23;
    }

    /// @dev Case-insensitive check that the header STARTS with `fieldA,fieldB` as whole columns —
    ///      either end-of-line right after (deposits.csv) or a further comma (claims.csv's third
    ///      column). One helper serves both files.
    function _expectHeader(string memory line, string memory fieldA, string memory fieldB) internal pure {
        bytes memory l = bytes(_lower(line));
        bytes memory p = bytes(string.concat(fieldA, ",", fieldB));
        bool ok = l.length >= p.length;
        for (uint256 i; ok && i < p.length; ++i) {
            if (l[i] != p[i]) ok = false;
        }
        if (ok && l.length > p.length && l[p.length] != 0x2c) ok = false; // partial column name
        if (!ok) revert BadHeader(line, string(p));
    }

    // -----------------------------------------------------------------------------------------
    // Row parsing
    // -----------------------------------------------------------------------------------------

    /// @dev Split on the single expected comma; exactly two fields (trimmed by _slice).
    function _splitTwo(string memory line, uint256 row) internal pure returns (string memory, string memory) {
        bytes memory b = bytes(line);
        uint256 commaAt = type(uint256).max;
        for (uint256 i; i < b.length; ++i) {
            if (b[i] != 0x2c) continue;
            if (commaAt != type(uint256).max) revert MalformedRow(row, line, "expected exactly one ','");
            commaAt = i;
        }
        if (commaAt == type(uint256).max) revert MalformedRow(row, line, "expected exactly one ','");
        return (_slice(b, 0, commaAt), _slice(b, commaAt + 1, b.length));
    }

    /// @dev `account,amount` row → validated fields. The parser cheatcodes are the final
    ///      authority on shape; the pre-checks exist to fail with a human-readable reason.
    function _parseDeposit(string memory line, uint256 row) internal pure returns (address account, uint256 amount) {
        (string memory a, string memory b) = _splitTwo(line, row);
        bytes memory ab = bytes(a);
        if (ab.length != 42 || ab[0] != 0x30 || ab[1] != 0x78) {
            revert MalformedRow(row, line, "account must be a 0x-prefixed 20-byte address");
        }
        account = vm.parseAddress(a);
        amount = vm.parseUint(b);
        if (amount == 0) {
            revert MalformedRow(row, line, "amount must be > 0 (zero-credit accounts are not leaves)");
        }
    }

    /// @dev `index,account,amount` row → validated fields.
    function _parseClaim(string memory line, uint256 row)
        internal
        pure
        returns (uint256 index, address account, uint256 amount)
    {
        bytes memory b = bytes(line);
        uint256 first = type(uint256).max;
        uint256 second = type(uint256).max;
        for (uint256 i; i < b.length; ++i) {
            if (b[i] != 0x2c) continue;
            if (first == type(uint256).max) {
                first = i;
            } else if (second == type(uint256).max) {
                second = i;
            } else {
                revert MalformedRow(row, line, "expected exactly two ','");
            }
        }
        if (second == type(uint256).max) revert MalformedRow(row, line, "expected exactly two ','");
        index = vm.parseUint(_slice(b, 0, first));
        account = vm.parseAddress(_slice(b, first + 1, second));
        amount = vm.parseUint(_slice(b, second + 1, b.length));
    }

    // -----------------------------------------------------------------------------------------
    // String helpers
    // -----------------------------------------------------------------------------------------

    function _slice(bytes memory b, uint256 start, uint256 end) private pure returns (string memory) {
        return string(_trim(_range(b, start, end)));
    }

    function _range(bytes memory b, uint256 start, uint256 end) private pure returns (bytes memory out) {
        out = new bytes(end - start);
        for (uint256 i = start; i < end; ++i) {
            out[i - start] = b[i];
        }
    }

    function _trim(bytes memory b) private pure returns (bytes memory) {
        uint256 start;
        uint256 end = b.length;
        while (start < end && (b[start] == 0x20 || b[start] == 0x09)) {
            ++start;
        }
        while (end > start && (b[end - 1] == 0x20 || b[end - 1] == 0x09)) {
            --end;
        }
        return _range(b, start, end);
    }

    function _lower(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            if (b[i] >= 0x41 && b[i] <= 0x5a) {
                b[i] |= 0x20;
            }
        }
        return string(b);
    }
}
