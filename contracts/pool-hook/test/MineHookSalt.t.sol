// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SurplusPoolHook} from "../src/SurplusPoolHook.sol";
import {PoolKey} from "../src/V4Minimal.sol";
import {HookMiner} from "../script/HookMiner.sol";
import {MineHookSalt} from "../script/MineHookSalt.s.sol";
import {Test} from "./Base.t.sol";

contract MineHookSaltTest is Test {
    uint160 internal constant FLAGS = 0x2000;
    // Arachnid's deterministic-deployment proxy runtime, as deployed on Base.
    bytes internal constant CREATE2_PROXY_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    address internal constant MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant INITIALIZER = address(0x1417);
    address internal constant V2 = address(0xB2);
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    uint24 internal constant LP_FEE = 12_000;
    int24 internal constant TICK_SPACING = 60;

    function _initCode() internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(SurplusPoolHook).creationCode, abi.encode(MANAGER, INITIALIZER, V2, WETH, LP_FEE, TICK_SPACING)
        );
    }

    function test_MinedSaltDeploysAtThePredictedAddressAndPassesTheFlagCheck() public {
        (bytes32 salt, address predicted) =
            HookMiner.find(address(this), keccak256(_initCode()), FLAGS, 0, HookMiner.MAX_ITERATIONS);
        SurplusPoolHook hook = new SurplusPoolHook{salt: salt}(MANAGER, INITIALIZER, V2, WETH, LP_FEE, TICK_SPACING);
        assertEq(address(hook), predicted, "deployed at the predicted address");
        assertEq(uint256(uint160(address(hook)) & 0x3FFF), FLAGS, "address carries exactly the hook flags");
        assertEq(hook.INITIALIZER(), INITIALIZER, "constructed with the mined arguments");
        vm.prank(MANAGER);
        hook.beforeInitialize(INITIALIZER, PoolKey(V2, WETH, LP_FEE, TICK_SPACING, address(hook)), 1 << 96);
    }

    function test_ScriptFlagsAreTheHooksDeclaredFlags() public {
        address probe = address(uint160(uint256(keccak256("mine.declared-flags"))));
        vm.etch(probe, vm.getDeployedCode("SurplusPoolHook.sol:SurplusPoolHook"));
        assertEq(uint256(new MineHookSalt().HOOK_FLAGS()), uint256(SurplusPoolHook(probe).REQUIRED_FLAGS()), "flags");
    }

    function test_MinedSaltIsTheSmallestMatchFromTheStart() public pure {
        bytes32 initCodeHash = keccak256(_initCode());
        address deployer = HookMiner.CREATE2_DEPLOYER;
        (bytes32 salt,) = HookMiner.find(deployer, initCodeHash, FLAGS, 0, HookMiner.MAX_ITERATIONS);
        for (uint256 s; s < uint256(salt); ++s) {
            address a = HookMiner.computeAddress(deployer, bytes32(s), initCodeHash);
            assertTrue((uint160(a) & 0x3FFF) != FLAGS, "an earlier salt also matches");
        }
        (bytes32 again,) = HookMiner.find(deployer, initCodeHash, FLAGS, uint256(salt), 1);
        assertEq(again, salt, "mining is deterministic");
        (bytes32 next,) = HookMiner.find(deployer, initCodeHash, FLAGS, uint256(salt) + 1, HookMiner.MAX_ITERATIONS);
        assertGt(uint256(next), uint256(salt), "a later start finds a later salt");
    }

    function test_MinedSaltDeploysThroughTheCreate2Proxy() public {
        vm.etch(HookMiner.CREATE2_DEPLOYER, CREATE2_PROXY_RUNTIME);
        bytes memory initCode = _initCode();
        (bytes32 salt, address predicted) =
            HookMiner.find(HookMiner.CREATE2_DEPLOYER, keccak256(initCode), FLAGS, 0, HookMiner.MAX_ITERATIONS);
        (bool ok, bytes memory ret) = HookMiner.CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        assertTrue(ok, "proxy deploy succeeded");
        assertEq(ret.length, 20, "proxy returns the 20-byte address");
        // Exactly 20 bytes, checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(address(bytes20(ret)), predicted, "proxy deployed at the predicted address");
        assertEq(SurplusPoolHook(predicted).REQUIRED_FLAGS(), FLAGS, "hook code at the predicted address");
    }

    function test_MinerRevertsWhenNoSaltMatchesWithinTheBudget() public {
        bytes32 initCodeHash = keccak256(_initCode());
        (bytes32 salt,) = HookMiner.find(HookMiner.CREATE2_DEPLOYER, initCodeHash, FLAGS, 0, HookMiner.MAX_ITERATIONS);
        vm.assume(uint256(salt) > 0);
        vm.expectRevert(abi.encodeWithSelector(HookMiner.SaltNotFound.selector, 0, uint256(salt)));
        this.findExternal(HookMiner.CREATE2_DEPLOYER, initCodeHash, 0, uint256(salt));
    }

    function findExternal(address deployer, bytes32 initCodeHash, uint256 start, uint256 iterations)
        external
        pure
        returns (bytes32 salt, address hook)
    {
        return HookMiner.find(deployer, initCodeHash, FLAGS, start, iterations);
    }

    function test_ScriptWritesTheSaltJson() public {
        string memory path = "output/hook-salt.test.json";
        vm.setEnv("HOOK_INITIALIZER", vm.toString(INITIALIZER));
        vm.setEnv("HOOK_CURRENCY0", vm.toString(V2));
        vm.setEnv("HOOK_CURRENCY1", vm.toString(WETH));
        vm.setEnv("HOOK_SALT_OUT", path);
        (bytes32 salt, address hook) = new MineHookSalt().run();

        (bytes32 expectedSalt, address expectedHook) =
            HookMiner.find(HookMiner.CREATE2_DEPLOYER, keccak256(_initCode()), FLAGS, 0, HookMiner.MAX_ITERATIONS);
        assertEq(salt, expectedSalt, "script mines the smallest salt against the CREATE2 proxy");
        assertEq(hook, expectedHook, "script returns the predicted address");

        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonAddress(json, ".deployer"), HookMiner.CREATE2_DEPLOYER, "json deployer");
        assertEq(vm.parseJsonBytes32(json, ".salt"), salt, "json salt");
        assertEq(vm.parseJsonAddress(json, ".address"), hook, "json address");
        assertEq(vm.parseJsonBytes32(json, ".initCodeHash"), keccak256(_initCode()), "json initCodeHash");
        assertEq(vm.parseJsonString(json, ".flags"), "0x2000", "json flags");
        assertEq(vm.parseJsonAddress(json, ".constructorArgs.poolManager"), MANAGER, "json poolManager");
        assertEq(vm.parseJsonAddress(json, ".constructorArgs.initializer"), INITIALIZER, "json initializer");
        assertEq(vm.parseJsonAddress(json, ".constructorArgs.currency0"), V2, "json currency0");
        assertEq(vm.parseJsonAddress(json, ".constructorArgs.currency1"), WETH, "json currency1");
        assertEq(vm.parseJsonUint(json, ".constructorArgs.lpFee"), LP_FEE, "json lpFee: the 1.2% default");
        assertEq(vm.parseJsonInt(json, ".constructorArgs.tickSpacing"), TICK_SPACING, "json tickSpacing");
    }
}
