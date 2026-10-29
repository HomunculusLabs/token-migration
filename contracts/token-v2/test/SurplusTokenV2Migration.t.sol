// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MigrationVault} from "@surplus/migration/src/MigrationVault.sol";
import {MockERC20} from "@surplus/migration/test/MockERC20.sol";
import {SurplusTokenV2} from "../src/SurplusTokenV2.sol";
import {Test} from "./Base.t.sol";

contract SurplusTokenV2MigrationTest is Test {
    // Only v1 is a test double. v2 is the real UUPS token behind an ERC1967 proxy.
    function test_VaultCannotReleaseV1BeforeRealV2BackingAndCanPayClaimAfterFunding() public {
        vm.chainId(8453);
        MockERC20 v1 = new MockERC20("Test-only v1", "TV1");
        SurplusTokenV2 implementation = new SurplusTokenV2();
        SurplusTokenV2 v2 = SurplusTokenV2(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(SurplusTokenV2.initialize, ("Test-only v2", "TV2", 1_000 ether, address(this)))
                )
            )
        );
        uint256 depositDeadline = block.timestamp + 1 days;
        MigrationVault vault = new MigrationVault(
            IERC20(address(v1)),
            IERC20(address(v2)),
            depositDeadline,
            depositDeadline + 3 days,
            7 days,
            180 days,
            10_000,
            false,
            address(this)
        );
        address holder = address(0xA11CE);
        address relayer = address(0xB0B);
        v1.mint(holder, 100 ether);
        vm.prank(holder);
        assertTrue(v1.approve(address(vault), 100 ether), "holder approves deposit");
        vm.prank(holder);
        vault.deposit(100 ether);
        assertEq(v1.balanceOf(address(vault)), 100 ether, "v1 held in custody");

        vm.warp(depositDeadline + 1);
        bytes32 leaf = keccak256(abi.encodePacked(uint256(0), holder, uint256(100 ether)));
        vault.commitRoot(leaf, 100 ether);
        vm.expectRevert(MigrationVault.ClaimsNotActive.selector);
        vault.withdrawV1ForSettlement(address(this), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.InsufficientBacking.selector, 100 ether, 0));
        vault.activateClaims();
        assertEq(v1.balanceOf(address(vault)), 100 ether, "failed activation cannot move v1");

        // Governance authorizes exactly the entitlement and mints directly to the vault.
        // Real launch allocation, ratio, dates and Safe identity remain separate decisions.
        v2.mint(address(vault), 100 ether);
        vault.activateClaims();
        (bool fullyFunded, uint256 backing, uint256 claimable,, bool active, uint256 claimed) = vault.verifySettlement();
        assertTrue(fullyFunded, "vault is fully backed");
        assertEq(backing, 100 ether, "v2 balance is real token backing");
        assertEq(claimable, 100 ether, "claim sum");
        assertTrue(active, "claims active");
        assertEq(claimed, 0, "nothing claimed yet");

        // MigrationVault pays the leaf beneficiary, not the relayer, using the actual v2 proxy.
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(relayer);
        vault.claim(0, holder, 100 ether, emptyProof);
        assertEq(v2.balanceOf(holder), 100 ether, "real proxy paid holder");
        assertEq(v2.balanceOf(relayer), 0, "relayer cannot redirect v2");
        assertEq(v2.totalSupply(), 100 ether, "minted backing equals claim");
        vault.withdrawV1ForSettlement(address(this), 100 ether);
        assertEq(v1.balanceOf(address(this)), 100 ether, "v1 settlement exit only after backed activation");
    }
}
