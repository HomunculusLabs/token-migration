// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationVault} from "../../src/MigrationVault.sol";
import {MockERC20} from "../MockERC20.sol";
import {TestMerkle} from "../TestMerkle.sol";
import {Test} from "../Base.t.sol";

/// @dev The launch-hardening surface. Declared separately so the regressions compile against a
///      vault that lacks it and fail there at runtime instead of at compile time.
interface ILaunchHardenedVault {
    function COMMIT_DEADLINE() external view returns (uint256);
    function expireCommit() external;
    function refund(address account) external;
    function rescueV1(address to) external;
}

/// @dev Shared fixture for the review-finding regressions (review-probe-0928, P1–P7).
abstract contract ReviewFindingsBase is Test {
    MockERC20 internal v1;
    MockERC20 internal v2;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal relayer = address(0x5E1A7);

    uint256 internal constant DEPOSIT_WINDOW = 1 days;
    uint256 internal constant COMMIT_WINDOW = 3 days;
    uint256 internal constant EXECUTION_WINDOW = 7 days;
    uint256 internal constant CLAIM_PERIOD = 180 days;

    function _vault(bool proRata, uint256 rateBps) internal returns (MigrationVault) {
        return _vault(proRata, rateBps, CLAIM_PERIOD);
    }

    function _vault(bool proRata, uint256 rateBps, uint256 claimPeriod) internal returns (MigrationVault vault) {
        v1 = new MockERC20("v1", "V1");
        v2 = new MockERC20("v2", "V2");
        uint256 depositDeadline = block.timestamp + DEPOSIT_WINDOW;
        vault = new MigrationVault(
            v1,
            v2,
            depositDeadline,
            depositDeadline + COMMIT_WINDOW,
            EXECUTION_WINDOW,
            claimPeriod,
            rateBps,
            proRata,
            address(this)
        );
    }

    function _deposit(MigrationVault vault, address who, uint256 amount) internal {
        v1.mint(who, amount);
        vm.startPrank(who);
        v1.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function _leaves2(address a, uint256 x, address b, uint256 y) internal pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](2);
        leaves[0] = TestMerkle.leaf(0, a, x);
        leaves[1] = TestMerkle.leaf(1, b, y);
    }

    function _root(bytes32[] memory leaves) internal pure returns (bytes32) {
        return TestMerkle.rootOf(_copy(leaves));
    }

    function _proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory) {
        return TestMerkle.proofFor(_copy(leaves), index);
    }

    function _copy(bytes32[] memory src) internal pure returns (bytes32[] memory dst) {
        dst = new bytes32[](src.length);
        for (uint256 i; i < src.length; ++i) {
            dst[i] = src[i];
        }
    }

    function _hardened(MigrationVault vault) internal pure returns (ILaunchHardenedVault) {
        return ILaunchHardenedVault(address(vault));
    }
}
