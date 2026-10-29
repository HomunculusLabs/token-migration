// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {TestnetV1} from "../src/testnet/TestnetV1.sol";
import {Test} from "./Base.t.sol";

interface ChainVm {
    function chainId(uint256) external;
}

contract TestnetV1Test is Test {
    function test_TestnetFixtureIsChainBoundAndMintIsCappedPerCallAndLifetime() public {
        ChainVm(address(vm)).chainId(84532);
        TestnetV1 token = new TestnetV1();
        assertEq(token.decimals(), 18, "fixture decimals");
        assertEq(token.totalSupply(), 0, "no real assets or premint");
        vm.prank(address(0xBEEF));
        token.faucet(address(0xBEEF), 1000 ether);
        assertEq(token.balanceOf(address(0xBEEF)), 1000 ether, "public bounded test mint");
        vm.expectRevert(abi.encodeWithSignature("FaucetLimit()"));
        token.faucet(address(this), 1000 ether + 1);
        vm.expectRevert(abi.encodeWithSignature("FaucetLimit()"));
        token.faucet(address(this), 0);
        for (uint256 i; i < 999; ++i) {
            token.faucet(address(this), 1000 ether);
        }
        vm.expectRevert(abi.encodeWithSignature("FaucetLimit()"));
        token.faucet(address(this), 1);
    }

    function test_TestnetFixtureCannotDeployOnBase() public {
        ChainVm(address(vm)).chainId(8453);
        vm.expectRevert(abi.encodeWithSignature("WrongChain()"));
        new TestnetV1();
    }
}
