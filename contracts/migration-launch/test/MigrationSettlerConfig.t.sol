// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationSettler} from "../src/MigrationSettler.sol";
import {Test} from "./Base.t.sol";

/// @dev The settler's constructor without a chain. Its launch behaviour runs on the fork in test/fork/.
contract MigrationSettlerConfigTest is Test {
    function _config(uint24 lpFee) internal pure returns (MigrationSettler.Config memory) {
        return MigrationSettler.Config({
            poolManager: address(0x9001),
            positionManager: address(0x9002),
            permit2: address(0x9003),
            safe: address(0x5AFE),
            v1: address(0x1111),
            weth: address(0x4200000000000000000000000000000000000006),
            v2: address(0x2222),
            v3Tail: address(0x3333),
            oldPoolId: keccak256("old pool"),
            lpFee: lpFee,
            tickSpacing: 60
        });
    }

    function test_PinsTheDecidedLpFee() public {
        assertEq(uint256(new MigrationSettler(_config(12_000)).LP_FEE()), 12_000, "LP_FEE");
    }

    /// The dynamic-fee flag would open the successor at 0% with nothing able to raise it, and v4 rejects any other fee
    /// above 100%, so neither can be the settler's successor fee.
    function test_RejectsADynamicOrOutOfRangeLpFee() public {
        uint24[3] memory bad = [uint24(0x800000), 1_000_001, type(uint24).max];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(MigrationSettler.InvalidConfig.selector));
            new MigrationSettler(_config(bad[i]));
        }
        assertEq(uint256(new MigrationSettler(_config(1_000_000)).LP_FEE()), 1_000_000, "the largest static fee");
    }

    /// `settle` is the Safe's to call and nothing else records that it ran, so it refuses a second run itself:
    /// a settled settler has `positionCount` = v2 ranges + 1, and a fresh one 0. `positionCount` is slot 4
    /// (`forge inspect MigrationSettler storage-layout`).
    function test_RefusesASecondSettle() public {
        MigrationSettler settler = new MigrationSettler(_config(12_000));
        vm.store(address(settler), bytes32(uint256(4)), bytes32(uint256(3)));
        assertEq(settler.positionCount(), 3, "positionCount");

        MigrationSettler.Params memory p;
        vm.prank(address(0x5AFE));
        vm.expectRevert(abi.encodeWithSelector(MigrationSettler.AlreadySettled.selector, 3));
        settler.settle(p);
    }
}
