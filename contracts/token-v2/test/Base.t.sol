// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Local forge-std stand-in, matching the other contracts/* suites without a new submodule.
interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function chainId(uint256 newChainId) external;
    function warp(uint256 newTimestamp) external;
    function load(address target, bytes32 slot) external view returns (bytes32);
    function addr(uint256 privateKey) external pure returns (address);
    function label(address account, string calldata newLabel) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
    function expectRevert() external;
    function expectRevert(bytes4 selector) external;
    function expectRevert(bytes calldata revertData) external;
}

contract Test {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function assertTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }

    function assertFalse(bool condition, string memory message) internal pure {
        require(!condition, message);
    }

    function assertEq(uint256 actual, uint256 expected, string memory message) internal pure {
        require(actual == expected, message);
    }

    function assertEq(address actual, address expected, string memory message) internal pure {
        require(actual == expected, message);
    }

    function assertEq(string memory actual, string memory expected, string memory message) internal pure {
        require(keccak256(bytes(actual)) == keccak256(bytes(expected)), message);
    }

    function assertEq(bytes32 actual, bytes32 expected, string memory message) internal pure {
        require(actual == expected, message);
    }
}
