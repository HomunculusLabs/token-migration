// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @dev A deliberately tiny stand-in for `forge-std`'s `Test`, mirroring contracts/payments' Base.t.sol
 *      (same rationale: pulling forge-std in means a 1.3 MB vendored copy or this repo's first git
 *      submodule, which changes the checkout flow for every engineer and CI job in a monorepo that
 *      has never needed one). This copy adds the phase/time cheatcodes (warp, addr, label, prank
 *      pairs) the migration suites need; assertions revert on failure, which is how `forge test`
 *      detects a failing test.
 */
interface Vm {
    function assume(bool condition) external pure;
    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function warp(uint256 timestamp) external;
    function addr(uint256 privateKey) external pure returns (address);
    function label(address account, string calldata newLabel) external;
    function expectRevert() external;
    function expectRevert(bytes4 selector) external;
    function expectRevert(bytes calldata revertData) external;
    /// @dev Expect the next emitted event to match the one emitted right after this call, with
    ///      per-field control (topic0 is always compared). Multiple pending expectations queue
    ///      and are consumed in emission order — the receipts suite relies on that to pin BOTH
    ///      events a single vault call emits.
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData, address emitter) external;
}

contract Test {
    /// @dev The canonical cheatcode address: `address(uint160(uint256(keccak256("hevm cheat code"))))`.
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function assertTrue(bool condition, string memory err) internal pure {
        require(condition, err);
    }

    function assertFalse(bool condition, string memory err) internal pure {
        require(!condition, err);
    }

    function assertEq(address a, address b, string memory err) internal pure {
        require(a == b, err);
    }

    function assertEq(address a, address b) internal pure {
        require(a == b, "assertEq(address) failed");
    }

    function assertEq(uint256 a, uint256 b, string memory err) internal pure {
        require(a == b, err);
    }

    function assertEq(uint256 a, uint256 b) internal pure {
        require(a == b, "assertEq(uint256) failed");
    }

    function assertEq(bytes32 a, bytes32 b, string memory err) internal pure {
        require(a == b, err);
    }

    function assertNotEq(uint256 a, uint256 b, string memory err) internal pure {
        require(a != b, err);
    }

    function assertGe(uint256 a, uint256 b, string memory err) internal pure {
        require(a >= b, err);
    }
}
