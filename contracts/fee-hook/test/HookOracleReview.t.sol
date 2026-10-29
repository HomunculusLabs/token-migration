// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SurplusFeeHook} from "../src/SurplusFeeHook.sol";
import {PoolKey, SwapParams} from "../src/V4Minimal.sol";
import {HookTest} from "./utils/HookTest.sol";
import {MockPoolManager} from "./utils/MockPoolManager.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Spec §3.5 oracle review of the hook diff. Each test failed on the reviewed hook (red evidence in
///      contracts/migration-launch/kit/evidence/review/) and passes after its fix.
contract HookOracleReviewTest is HookTest {
    address internal constant TREASURY = address(0x7EA5);
    address internal constant INITIALIZER = address(0x1417);
    address internal constant STRANGER = address(0xBAD);
    uint24 internal constant LP_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    SurplusFeeHook internal hook;
    MockPoolManager internal manager;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal key;

    function setUp() public {
        manager = new MockPoolManager();
        MockERC20 a = new MockERC20("Token A", "A");
        MockERC20 b = new MockERC20("Token B", "B");
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        hook = _deployHook(
            "oracle.hook",
            HookArgs(address(manager), TREASURY, INITIALIZER, address(token0), address(token1), LP_FEE, TICK_SPACING)
        );
        key = PoolKey(address(token0), address(token1), LP_FEE, TICK_SPACING, address(hook));
        token1.mint(address(manager), 1e30);
    }

    /// Oracle round 2, hook finding 2. Tokens sent to the hook outside afterSwap (a mistaken transfer, dust)
    /// were stranded: withdrawals stop at owed - paid, so the excess could never leave. The treasury must be
    /// able to recover exactly the balance above the fees still owed, and never a fee someone is owed.
    function test_ORACLE_hook_StrayTokensAreRecoverable() public {
        // One real swap: 2 token1 out, fee 0.03 token1, owed and unpaid.
        vm.prank(address(manager));
        hook.afterSwap(address(0x5AB), key, SwapParams(true, -1e18, 0), _delta(-1e18, 2e18), "");
        uint256 fee = 2e18 * 15_000 / 1_000_000;
        // A holder sends 5 token1 to the hook by mistake.
        token1.mint(STRANGER, 5e18);
        vm.prank(STRANGER);
        require(token1.transfer(address(hook), 5e18), "stray transfer");

        (bool ok,) =
            address(hook).call(abi.encodeWithSignature("recoverExcess(address,address)", address(token1), STRANGER));
        assertFalse(ok, "only the treasury can recover");

        vm.prank(TREASURY);
        (ok,) = address(hook).call(abi.encodeWithSignature("recoverExcess(address,address)", address(token1), STRANGER));
        assertTrue(ok, "the treasury recovers the stray tokens");
        assertEq(token1.balanceOf(STRANGER), 5e18, "exactly the stray amount came back");
        assertEq(token1.balanceOf(address(hook)), fee, "the owed fee stayed in the hook");

        vm.prank(TREASURY);
        (ok,) = address(hook).call(abi.encodeWithSignature("recoverExcess(address,address)", address(token1), STRANGER));
        assertFalse(ok, "nothing above the owed fees is left to recover");
    }
}
