// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SurplusPoolHook} from "../src/SurplusPoolHook.sol";
import {PoolKey, SwapParams} from "../src/V4Minimal.sol";
import {HookTest} from "./utils/HookTest.sol";

/// @dev Unit suite: the hook's permissions, constructor checks and initializer gate. The real-manager behaviour lives
///      in test/fork/.
contract SurplusPoolHookTest is HookTest {
    // BEFORE_INITIALIZE only, restated independently of the hook.
    uint160 internal constant GATE_FLAGS = 0x2000;
    uint160 internal constant PRICE = 1 << 96;

    address internal constant MANAGER = address(0x9001);
    address internal constant INITIALIZER = address(0x1417);
    address internal constant CURRENCY0 = address(0xC0);
    address internal constant CURRENCY1 = address(0xC1);
    uint24 internal constant LP_FEE = 12_000; // pips: 1.2%
    int24 internal constant TICK_SPACING = 60;
    address internal constant STRANGER = address(0xBAD);

    SurplusPoolHook internal hook;

    function setUp() public {
        hook = _deployHook("unit.hook", _args());
    }

    function _args() internal pure returns (HookArgs memory) {
        return HookArgs(MANAGER, INITIALIZER, CURRENCY0, CURRENCY1, LP_FEE, TICK_SPACING);
    }

    function _officialKey(address hooks) internal pure returns (PoolKey memory) {
        return PoolKey(CURRENCY0, CURRENCY1, LP_FEE, TICK_SPACING, hooks);
    }

    /// The PoolManager reads permissions from the address. Without the BEFORE_INITIALIZE bit the gate silently never
    /// runs; with any other bit the manager would call the hook on swaps or liquidity changes. 0x2044 is the old fee
    /// hook's set (BEFORE_INITIALIZE | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA).
    function test_ConstructorRequiresExactlyTheInitializeBit() public {
        bytes memory initCode = _hookInitCode(_args());
        uint160[7] memory wrong = [uint160(0x2044), 0x2040, 0x2080, 0x2800, 0x1000, 0x3FFF, 0];
        for (uint256 i; i < wrong.length; ++i) {
            address at = _flaggedAddress("unit.flags", wrong[i]);
            (bool ok, bytes memory ret) = _constructAt(at, initCode);
            assertFalse(ok, "constructed at an address without exactly the gate flag");
            assertEq(ret, abi.encodeWithSelector(SurplusPoolHook.InvalidHookAddress.selector, at), "revert reason");
        }
        (bool deployed,) = _constructAt(_flaggedAddress("unit.flags", GATE_FLAGS), initCode);
        assertTrue(deployed, "constructs at an address with exactly the gate flag");
        assertEq(uint256(hook.REQUIRED_FLAGS()), GATE_FLAGS, "declares BEFORE_INITIALIZE only");
    }

    /// A zero manager or initializer bricks the hook, a zero currency is native ETH, and v4 rejects unsorted
    /// currencies, so none of these can describe a launchable official pool.
    function test_ConstructorRejectsZeroAddressesAndUnsortedCurrencies() public {
        address at = _flaggedAddress("unit.ctor", GATE_FLAGS);
        bytes memory zero = abi.encodeWithSelector(SurplusPoolHook.ZeroAddress.selector);
        HookArgs[4] memory zeroed = [_args(), _args(), _args(), _args()];
        zeroed[0].poolManager = address(0);
        zeroed[1].initializer = address(0);
        zeroed[2].currency0 = address(0);
        zeroed[3].currency1 = address(0);
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
                abi.encodeWithSelector(
                    SurplusPoolHook.CurrenciesOutOfOrder.selector, misordered[i].currency0, misordered[i].currency1
                ),
                "ordering revert reason"
            );
        }
    }

    /// The dynamic-fee flag (0x800000) would open the pool at 0% with nothing able to raise it, and v4 rejects any
    /// other fee above 100%.
    function test_ConstructorRejectsADynamicOrOutOfRangeLpFee() public {
        address at = _flaggedAddress("unit.fee", GATE_FLAGS);
        uint24[3] memory bad = [uint24(0x800000), 1_000_001, type(uint24).max];
        for (uint256 i; i < bad.length; ++i) {
            HookArgs memory a = _args();
            a.lpFee = bad[i];
            (bool ok, bytes memory ret) = _constructAt(at, _hookInitCode(a));
            assertFalse(ok, "constructed with a fee v4 would not charge");
            assertEq(ret, abi.encodeWithSelector(SurplusPoolHook.InvalidLpFee.selector, bad[i]), "fee revert reason");
        }
        HookArgs memory max = _args();
        max.lpFee = 1_000_000;
        (bool deployed,) = _constructAt(at, _hookInitCode(max));
        assertTrue(deployed, "the largest static fee is accepted");
    }

    /// The launch helper reads INITIALIZER() before initializing, and fork tests and the CREATE2 deploy both place the
    /// hook's runtime code at its address. Every launch parameter must therefore live in the code (immutables), never
    /// in storage: a copy of the runtime at a fresh, storage-empty address still answers every getter and still gates.
    function test_LaunchParametersAreImmutablesThatSurviveEtch() public {
        SurplusPoolHook copy = SurplusPoolHook(_flaggedAddress("unit.copy", GATE_FLAGS));
        vm.etch(address(copy), address(hook).code);
        SurplusPoolHook[2] memory hooks = [hook, copy];
        for (uint256 i; i < hooks.length; ++i) {
            assertEq(hooks[i].POOL_MANAGER(), MANAGER, "POOL_MANAGER");
            assertEq(hooks[i].INITIALIZER(), INITIALIZER, "INITIALIZER");
            assertEq(hooks[i].CURRENCY0(), CURRENCY0, "CURRENCY0");
            assertEq(hooks[i].CURRENCY1(), CURRENCY1, "CURRENCY1");
            assertEq(uint256(hooks[i].LP_FEE()), LP_FEE, "LP_FEE");
            assertEq(int256(hooks[i].TICK_SPACING()), TICK_SPACING, "TICK_SPACING");
            vm.prank(MANAGER);
            bytes4 selector = hooks[i].beforeInitialize(INITIALIZER, _officialKey(address(hooks[i])), PRICE);
            assertEq(bytes32(selector), bytes32(SurplusPoolHook.beforeInitialize.selector), "gate accepts the launch");
        }
    }

    function test_BeforeInitializeRejectsCallersOtherThanThePoolManager() public {
        address[2] memory callers = [STRANGER, INITIALIZER];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(SurplusPoolHook.NotPoolManager.selector, callers[i]));
            hook.beforeInitialize(INITIALIZER, _officialKey(address(hook)), PRICE);
        }
    }

    function test_BeforeInitializeRejectsSendersOtherThanTheInitializer() public {
        address[3] memory senders = [STRANGER, MANAGER, address(hook)];
        for (uint256 i; i < senders.length; ++i) {
            vm.prank(MANAGER);
            vm.expectRevert(abi.encodeWithSelector(SurplusPoolHook.NotInitializer.selector, senders[i]));
            hook.beforeInitialize(senders[i], _officialKey(address(hook)), PRICE);
        }
    }

    /// Includes the old 0.30% fee: a key with any fee other than the decided one cannot name the hook.
    function test_BeforeInitializeRejectsEveryKeyButTheOfficialOne() public {
        PoolKey[7] memory keys;
        for (uint256 i; i < keys.length; ++i) {
            keys[i] = _officialKey(address(hook));
        }
        keys[0].currency0 = address(0xB0);
        keys[1].currency1 = address(0xC2);
        keys[2].fee = 3000;
        keys[3].fee = 0x800000;
        keys[4].tickSpacing = 10;
        keys[5].hooks = STRANGER;
        (keys[6].currency0, keys[6].currency1) = (address(0), CURRENCY0);
        for (uint256 i; i < keys.length; ++i) {
            vm.prank(MANAGER);
            vm.expectRevert(SurplusPoolHook.UnofficialPoolKey.selector);
            hook.beforeInitialize(INITIALIZER, keys[i], PRICE);
        }
    }

    /// Nothing but the gate exists: no swap or liquidity callback, no payable entry, so the hook can neither charge a
    /// swap nor hold ETH.
    function test_HasNoSwapOrLiquidityCallbacksAndTakesNoEth() public {
        PoolKey memory key = _officialKey(address(hook));
        bytes[3] memory calls = [
            abi.encodeWithSignature(
                "beforeSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),bytes)",
                STRANGER,
                key,
                SwapParams(true, -1e18, 0),
                ""
            ),
            abi.encodeWithSignature(
                "afterSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),int256,bytes)",
                STRANGER,
                key,
                SwapParams(true, -1e18, 0),
                int256(0),
                ""
            ),
            abi.encodeWithSignature(
                "afterInitialize(address,(address,address,uint24,int24,address),uint160,int24)",
                STRANGER,
                key,
                PRICE,
                int24(0)
            )
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(MANAGER);
            (bool ok,) = address(hook).call(calls[i]);
            assertFalse(ok, "the hook answered a callback other than beforeInitialize");
        }
        vm.deal(address(this), 1 ether);
        (bool paid,) = address(hook).call{value: 1 ether}("");
        assertFalse(paid, "the hook accepts native ETH");
    }
}
