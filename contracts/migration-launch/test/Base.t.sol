// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @dev A deliberately tiny stand-in for `forge-std`'s `Test`, following contracts/migration's Base.t.sol and
 *      for the same reason: no vendored forge-std and no git submodule in this monorepo. This copy adds the
 *      cheatcodes the settler's fork suite needs (etch, sign, state snapshots, env). Assertions revert on
 *      failure, which is how `forge test` detects a failing test.
 */
interface Vm {
    function prank(address sender) external;
    function record() external;
    function accesses(address target) external returns (bytes32[] memory readSlots, bytes32[] memory writeSlots);
    function startPrank(address sender) external;
    function stopPrank() external;
    function warp(uint256 timestamp) external;
    function addr(uint256 privateKey) external pure returns (address);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function etch(address target, bytes calldata code) external;
    function deal(address account, uint256 newBalance) external;
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256);
    function snapshotState() external returns (uint256 snapshotId);
    function revertToState(uint256 snapshotId) external returns (bool success);
    function expectRevert(bytes calldata revertData) external;
}

contract Test {
    /// @dev The canonical cheatcode address: `address(uint160(uint256(keccak256("hevm cheat code"))))`.
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    event log_named_uint(string key, uint256 val);

    function assertTrue(bool condition, string memory err) internal pure {
        require(condition, err);
    }

    function assertEq(address a, address b, string memory err) internal pure {
        require(a == b, err);
    }

    function assertEq(uint256 a, uint256 b, string memory err) internal pure {
        require(a == b, err);
    }

    function assertEq(bytes32 a, bytes32 b, string memory err) internal pure {
        require(a == b, err);
    }
}
