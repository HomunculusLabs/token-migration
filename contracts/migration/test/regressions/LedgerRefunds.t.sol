// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationVault} from "../../src/MigrationVault.sol";
import {TestMerkle} from "../TestMerkle.sol";
import {ReviewFindingsBase} from "./ReviewFindingsBase.sol";

/// @dev P3 + P4: safety-net refunds must pay the on-chain ledger, never the root.
contract LedgerRefundsTest is ReviewFindingsBase {
    /// P3: refunds paid from the ROOT turned a wrong root plus seven idle days into a full drain
    /// to a non-depositor. Refunds now pay each account its own ledger credit.
    function test_P3_TimeoutRefundsPayTheLedgerNotTheRoot() public {
        for (uint256 k; k < 2; ++k) {
            MigrationVault vault = _vault(k == 1, 10_000);
            _deposit(vault, alice, 100 ether);
            _deposit(vault, bob, 100 ether);
            vm.warp(vault.DEPOSIT_DEADLINE() + 1);
            address sink = address(0xBAD);
            vault.commitRoot(TestMerkle.leaf(0, sink, 200 ether), 200 ether); // a wrong one-leaf root
            vm.warp(vault.rootCommittedAt() + EXECUTION_WINDOW + 1);
            vault.expireExecution();

            (bool paidAgainstRoot,) = address(vault)
                .call(
                    abi.encodeWithSignature(
                        "refund(uint256,address,uint256,bytes32[])", 0, sink, 200 ether, new bytes32[](0)
                    )
                );
            assertFalse(paidAgainstRoot, "no refund is payable against the root");
            vm.startPrank(relayer);
            _hardened(vault).refund(alice);
            _hardened(vault).refund(bob);
            vm.stopPrank();
            assertEq(v1.balanceOf(sink), 0, "the wrong root's beneficiary gets nothing");
            assertEq(v1.balanceOf(alice), 100 ether, "alice gets her ledger credit");
            assertEq(v1.balanceOf(bob), 100 ether, "bob gets his ledger credit");
            vm.warp(block.timestamp + 1);
        }
    }

    /// P4: at a non-1:1 root, root-paid refunds were a bank run (the first refunder took the
    /// last one's v1). Ledger refunds return each depositor exactly their deposit at any ratio.
    function test_P4_BonusRootCannotTurnRefundsIntoABankRun() public {
        MigrationVault vault = _vault(false, 11_000);
        _deposit(vault, alice, 100 ether);
        _deposit(vault, bob, 100 ether);
        vm.warp(vault.DEPOSIT_DEADLINE() + 1);
        vault.commitRoot(_root(_leaves2(alice, 110 ether, bob, 110 ether)), 220 ether);
        vm.warp(vault.rootCommittedAt() + EXECUTION_WINDOW + 1);
        vault.expireExecution();

        _hardened(vault).refund(alice);
        _hardened(vault).refund(bob);
        assertEq(v1.balanceOf(alice), 100 ether, "alice gets exactly her deposit");
        assertEq(v1.balanceOf(bob), 100 ether, "bob is not short");
        assertEq(v1.balanceOf(address(vault)), 0, "nothing stranded");
    }

    function test_RefundIsOncePerCredit() public {
        MigrationVault vault = _vault(false, 10_000);
        _deposit(vault, alice, 100 ether);
        vault.cancel();
        _hardened(vault).refund(alice);
        vm.expectRevert(MigrationVault.NothingToWithdraw.selector);
        _hardened(vault).refund(alice);
        assertEq(v1.balanceOf(alice), 100 ether, "paid once");
    }
}
