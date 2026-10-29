// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "./Base.t.sol";
import {SurplusTokenV2} from "../src/SurplusTokenV2.sol";
import {SurplusTokenV2BaseSepolia as Sepolia} from "../src/SurplusTokenV2BaseSepolia.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract SepoliaTokenTest is Test {
    function test_SepoliaInitializesOnlyOn84532WithSafeRolesAndNoEOAPowers() public {
        vm.chainId(84532);
        Sepolia implementation = new Sepolia();
        Sepolia token = Sepolia(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(Sepolia.initialize, ("TEST ONLY", "TEST", 100 ether, address(this)))
                )
            )
        );
        assertEq(token.CANONICAL_CHAIN_ID(), 84532, "correct public chain identity");
        assertEq(token.totalSupply(), 0, "zero supply");
        bytes32[4] memory roles = [bytes32(0), token.MINTER_ROLE(), token.BURNER_ROLE(), token.UPGRADER_ROLE()];
        for (uint256 i; i < roles.length; ++i) {
            assertTrue(token.hasRole(roles[i], address(this)), "governance holds every role");
            assertFalse(token.hasRole(roles[i], address(0xBEEF)), "EOA has no role");
        }
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        implementation.initialize("TEST", "TEST", 1, address(this));
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        token.initialize("TEST", "TEST", 1, address(this));
        token.mint(address(this), 100 ether);
        vm.expectRevert(bytes("ERC20Capped: cap exceeded"));
        token.mint(address(this), 1);
        token.burn(1 ether);
        assertEq(token.totalSupply(), 99 ether, "governed burn lowers supply");
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        token.mint(address(0xBEEF), 1);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        token.upgradeTo(address(implementation));
    }

    function test_SepoliaRejectsProductionAndArbitraryChains() public {
        Sepolia implementation = new Sepolia();
        uint256[3] memory chains = [uint256(8453), 1, 31337];
        for (uint256 i; i < chains.length; ++i) {
            vm.chainId(chains[i]);
            vm.expectRevert(abi.encodeWithSelector(Sepolia.InvalidCanonicalChain.selector, chains[i]));
            new ERC1967Proxy(
                address(implementation), abi.encodeCall(Sepolia.initialize, ("TEST", "TEST", 1, address(this)))
            );
        }
    }

    function test_ProductionStillRejectsSepolia() public {
        vm.chainId(84532);
        SurplusTokenV2 implementation = new SurplusTokenV2();
        vm.expectRevert(abi.encodeWithSelector(SurplusTokenV2.InvalidCanonicalChain.selector, 84532));
        new ERC1967Proxy(
            address(implementation), abi.encodeCall(SurplusTokenV2.initialize, ("TEST", "TEST", 1, address(this)))
        );
    }
}
