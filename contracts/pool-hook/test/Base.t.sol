// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @dev A deliberately tiny stand-in for `forge-std`'s `Test`, mirroring the other contracts/* suites
 *      (forge-std would mean a vendored copy or this monorepo's first git submodule). The Vm surface
 *      holds only the cheatcodes these suites call; assertions revert on failure, which is how
 *      `forge test` detects a failing test.
 */
interface Vm {
    function assume(bool condition) external pure;
    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function deal(address account, uint256 newBalance) external;
    function etch(address target, bytes calldata code) external;
    function store(address target, bytes32 slot, bytes32 value) external;
    function label(address account, string calldata newLabel) external;
    function getDeployedCode(string calldata artifactPath) external view returns (bytes memory);
    function skip(bool skipTest, string calldata reason) external;
    function activeFork() external view returns (uint256 forkId);
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256);
    function setEnv(string calldata name, string calldata value) external;
    function toString(address value) external pure returns (string memory);
    function readFile(string calldata path) external view returns (string memory);
    function parseJsonAddress(string calldata json, string calldata key) external pure returns (address);
    function parseJsonBytes32(string calldata json, string calldata key) external pure returns (bytes32);
    function parseJsonUint(string calldata json, string calldata key) external pure returns (uint256);
    function parseJsonInt(string calldata json, string calldata key) external pure returns (int256);
    function parseJsonString(string calldata json, string calldata key) external pure returns (string memory);
    function expectRevert() external;
    function expectRevert(bytes4 selector) external;
    function expectRevert(bytes calldata revertData) external;
}

contract Test {
    /// @dev The canonical cheatcode address: `address(uint160(uint256(keccak256("hevm cheat code"))))`.
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    /// @dev DSTest-compatible log events: forge decodes these into the `Logs:` block of `-vv` output.
    event log_named_string(string key, string val);
    event log_named_decimal_uint(string key, uint256 val, uint256 decimals);

    function assertTrue(bool condition, string memory err) internal pure {
        require(condition, err);
    }

    function assertFalse(bool condition, string memory err) internal pure {
        require(!condition, err);
    }

    function assertEq(uint256 a, uint256 b, string memory err) internal pure {
        require(a == b, err);
    }

    function assertEq(int256 a, int256 b, string memory err) internal pure {
        require(a == b, err);
    }

    function assertEq(address a, address b, string memory err) internal pure {
        require(a == b, err);
    }

    function assertEq(bytes32 a, bytes32 b, string memory err) internal pure {
        require(a == b, err);
    }

    function assertEq(bytes memory a, bytes memory b, string memory err) internal pure {
        require(keccak256(a) == keccak256(b), err);
    }

    function assertEq(string memory a, string memory b, string memory err) internal pure {
        require(keccak256(bytes(a)) == keccak256(bytes(b)), err);
    }

    function assertGt(uint256 a, uint256 b, string memory err) internal pure {
        require(a > b, err);
    }

    function assertGe(uint256 a, uint256 b, string memory err) internal pure {
        require(a >= b, err);
    }

    function assertLe(uint256 a, uint256 b, string memory err) internal pure {
        require(a <= b, err);
    }
}
