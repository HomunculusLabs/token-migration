// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HookFlags} from "../src/V4Minimal.sol";

/// @notice Finds a CREATE2 salt that places a v4 hook at an address carrying exactly its permission bits.
library HookMiner {
    /// @notice Arachnid's deterministic-deployment proxy (on Base and most EVM chains): CREATE2 with
    ///         calldata = salt ++ initCode, returning the 20-byte address. Anyone can call it, and a copy-deploy
    ///         of the same init code and salt yields the identical contract, so nothing is gained by racing it.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice 2^20 tries: each salt hits with probability 2^-14, so a miss has probability e^-64. At ~175 gas
    ///         per try the whole budget stays under forge's default 2^30 gas limit.
    uint256 internal constant MAX_ITERATIONS = 1 << 20;

    error SaltNotFound(uint256 startSalt, uint256 iterations);

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @notice The smallest salt >= `startSalt` whose CREATE2 address has exactly `flags` in its low 14 bits.
    function find(address deployer, bytes32 initCodeHash, uint160 flags, uint256 startSalt, uint256 maxIterations)
        internal
        pure
        returns (bytes32 salt, address hook)
    {
        // One preimage buffer, salt rewritten in place: allocating per try would grow EVM memory, whose cost is
        // quadratic. Layout: 0xff (1 byte) | deployer (20) | salt (32) at data offset 21 | initCodeHash (32).
        bytes memory preimage = abi.encodePacked(bytes1(0xff), deployer, bytes32(0), initCodeHash);
        uint256 end = startSalt + maxIterations;
        for (uint256 s = startSalt; s < end; ++s) {
            bytes32 digest;
            assembly ("memory-safe") {
                mstore(add(preimage, 0x35), s)
                digest := keccak256(add(preimage, 0x20), 85)
            }
            address candidate = address(uint160(uint256(digest)));
            if ((uint160(candidate) & HookFlags.ALL_HOOK_MASK) == flags) return (bytes32(s), candidate);
        }
        revert SaltNotFound(startSalt, maxIterations);
    }
}
