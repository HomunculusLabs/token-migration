// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "../src/V4Minimal.sol";
import {HookTest} from "./utils/HookTest.sol";

/// @dev The surface the launch helper relies on. Declared here, with expected errors spelled as signatures, so these
///      regressions compile, and fail, against a hook without the fixes.
interface ILaunchHook {
    function POOL_MANAGER() external view returns (address);
    function TREASURY() external view returns (address);
    function INITIALIZER() external view returns (address);
    function CURRENCY0() external view returns (address);
    function CURRENCY1() external view returns (address);
    function LP_FEE() external view returns (uint24);
    function TICK_SPACING() external view returns (int24);
    function REQUIRED_FLAGS() external view returns (uint160);
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4);
}

/// @dev Unit-level regressions for the fee-hook review findings.
contract HookReviewRegressionsTest is HookTest {
    // BEFORE_INITIALIZE | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, restated independently of the hook.
    uint160 internal constant GATED_FLAGS = 0x2044;
    uint160 internal constant PRICE = 1 << 96;

    address internal constant MANAGER = address(0x9001);
    address internal constant TREASURY = address(0x7EA5);
    address internal constant INITIALIZER = address(0x1417);
    address internal constant CURRENCY0 = address(0xC0);
    address internal constant CURRENCY1 = address(0xC1);
    uint24 internal constant LP_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    address internal constant STRANGER = address(0xBAD);

    ILaunchHook internal hook;

    function setUp() public {
        hook = ILaunchHook(address(_deployHook("h3.hook", _args())));
    }

    function _args() internal pure returns (HookArgs memory) {
        return HookArgs(MANAGER, TREASURY, INITIALIZER, CURRENCY0, CURRENCY1, LP_FEE, TICK_SPACING);
    }

    function _officialKey(address hooks) internal pure returns (PoolKey memory) {
        return PoolKey(CURRENCY0, CURRENCY1, LP_FEE, TICK_SPACING, hooks);
    }

    /// H3: the PoolManager reads permissions from the address, so a hook deployed without the BEFORE_INITIALIZE
    /// bit silently never runs its gate, and one with extra bits gets calls it cannot answer.
    function test_H3_ConstructorRequiresExactlyTheGatedFlagBits() public {
        bytes memory initCode = _hookInitCode(_args());
        uint160[6] memory wrong = [uint160(0x0044), 0x2040, 0x2004, 0x2045, 0x3FFF, 0];
        for (uint256 i; i < wrong.length; ++i) {
            address at = _flaggedAddress("h3.flags", wrong[i]);
            (bool ok, bytes memory ret) = _constructAt(at, initCode);
            assertFalse(ok, "constructed at an address without exactly the gated flags");
            assertEq(ret, abi.encodeWithSignature("InvalidHookAddress(address)", at), "revert reason");
        }
        (bool deployed,) = _constructAt(_flaggedAddress("h3.flags", GATED_FLAGS), initCode);
        assertTrue(deployed, "constructs at an address with exactly the gated flags");
    }

    /// H3: a zero initializer, manager or treasury bricks the hook, a zero currency is native ETH (out of scope),
    /// and v4 rejects unsorted currencies, so none of these can describe a launchable official pool.
    function test_H3_ConstructorRejectsZeroAddressesAndUnsortedCurrencies() public {
        address at = _flaggedAddress("h3.ctor", GATED_FLAGS);
        bytes memory zero = abi.encodeWithSignature("ZeroAddress()");
        HookArgs[5] memory zeroed = [_args(), _args(), _args(), _args(), _args()];
        zeroed[0].poolManager = address(0);
        zeroed[1].treasury = address(0);
        zeroed[2].initializer = address(0);
        zeroed[3].currency0 = address(0);
        zeroed[4].currency1 = address(0);
        for (uint256 i; i < zeroed.length; ++i) {
            (bool ok, bytes memory ret) = _constructAt(at, _hookInitCode(zeroed[i]));
            assertFalse(ok, "constructed with a zero address");
            assertEq(ret, zero, "zero-address revert reason");
        }

        HookArgs memory unsorted = _args();
        (unsorted.currency0, unsorted.currency1) = (CURRENCY1, CURRENCY0);
        HookArgs memory equal = _args();
        equal.currency1 = CURRENCY0;
        HookArgs[2] memory misordered = [unsorted, equal];
        for (uint256 i; i < misordered.length; ++i) {
            (bool ok, bytes memory ret) = _constructAt(at, _hookInitCode(misordered[i]));
            assertFalse(ok, "constructed with currency0 >= currency1");
            assertEq(
                ret,
                abi.encodeWithSignature(
                    "CurrenciesOutOfOrder(address,address)", misordered[i].currency0, misordered[i].currency1
                ),
                "ordering revert reason"
            );
        }
    }

    /// H3: the launch helper reads INITIALIZER() before initializing, and fork tests and the CREATE2 deploy both
    /// place the hook's runtime code at its address. Every launch parameter must therefore live in the code
    /// (immutables), never in storage: a copy of the runtime at a fresh, storage-empty address still answers
    /// every getter and still gates.
    function test_H3_LaunchParametersAreImmutablesThatSurviveEtch() public {
        ILaunchHook copy = ILaunchHook(_flaggedAddress("h3.copy", GATED_FLAGS));
        vm.etch(address(copy), address(hook).code);
        ILaunchHook[2] memory hooks = [hook, copy];
        for (uint256 i; i < hooks.length; ++i) {
            assertEq(hooks[i].POOL_MANAGER(), MANAGER, "POOL_MANAGER");
            assertEq(hooks[i].TREASURY(), TREASURY, "TREASURY");
            assertEq(hooks[i].INITIALIZER(), INITIALIZER, "INITIALIZER");
            assertEq(hooks[i].CURRENCY0(), CURRENCY0, "CURRENCY0");
            assertEq(hooks[i].CURRENCY1(), CURRENCY1, "CURRENCY1");
            assertEq(uint256(hooks[i].LP_FEE()), LP_FEE, "LP_FEE");
            assertEq(int256(hooks[i].TICK_SPACING()), TICK_SPACING, "TICK_SPACING");
            assertEq(uint256(hooks[i].REQUIRED_FLAGS()), GATED_FLAGS, "REQUIRED_FLAGS");
            vm.prank(MANAGER);
            bytes4 selector = hooks[i].beforeInitialize(INITIALIZER, _officialKey(address(hooks[i])), PRICE);
            assertEq(bytes32(selector), bytes32(ILaunchHook.beforeInitialize.selector), "gate accepts the launch");
        }
    }

    function test_H3_BeforeInitializeRejectsCallersOtherThanThePoolManager() public {
        address[3] memory callers = [STRANGER, INITIALIZER, TREASURY];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSignature("NotPoolManager(address)", callers[i]));
            hook.beforeInitialize(INITIALIZER, _officialKey(address(hook)), PRICE);
        }
    }

    function test_H3_BeforeInitializeRejectsSendersOtherThanTheInitializer() public {
        address[4] memory senders = [STRANGER, TREASURY, MANAGER, address(hook)];
        for (uint256 i; i < senders.length; ++i) {
            vm.prank(MANAGER);
            vm.expectRevert(abi.encodeWithSignature("NotInitializer(address)", senders[i]));
            hook.beforeInitialize(senders[i], _officialKey(address(hook)), PRICE);
        }
    }

    function test_H3_BeforeInitializeRejectsEveryKeyButTheOfficialOne() public {
        PoolKey[6] memory keys;
        for (uint256 i; i < keys.length; ++i) {
            keys[i] = _officialKey(address(hook));
        }
        keys[0].currency0 = address(0xB0);
        keys[1].currency1 = address(0xC2);
        keys[2].fee = 500;
        keys[3].tickSpacing = 10;
        keys[4].hooks = STRANGER;
        (keys[5].currency0, keys[5].currency1) = (address(0), CURRENCY0);
        for (uint256 i; i < keys.length; ++i) {
            vm.prank(MANAGER);
            vm.expectRevert(abi.encodeWithSignature("UnofficialPoolKey()"));
            hook.beforeInitialize(INITIALIZER, keys[i], PRICE);
        }
    }
}
