// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SurplusPoolHook} from "../../src/SurplusPoolHook.sol";
import {PoolKey} from "../../src/V4Minimal.sol";
import {ForkHarness} from "./ForkHarness.sol";

/// @dev The initializer gate against the real PoolManager, before any pool exists, once per currency order.
abstract contract PoolGateForkSuite is ForkHarness {
    /// Without the gate anyone could initialize the official key first, at a price of their choosing, and the
    /// launch's own initialize would then revert.
    function test_OnlyTheInitializerCanInitializeTheOfficialKey() public {
        vm.prank(STRANGER);
        vm.expectRevert(_gateRevert(abi.encodeWithSelector(SurplusPoolHook.NotInitializer.selector, STRANGER)));
        MANAGER.initialize(official, _startPrice());
        _launch(official);
        assertGt(uint256(_sqrtPrice(official)), 0, "initializer launched the official pool");
    }

    function test_NoOtherPoolKeyCanNameTheHook() public {
        PoolKey[] memory rivals = _rivalKeys();
        for (uint256 i; i < rivals.length; ++i) {
            vm.prank(INITIALIZER);
            vm.expectRevert(_gateRevert(abi.encodeWithSelector(SurplusPoolHook.UnofficialPoolKey.selector)));
            MANAGER.initialize(rivals[i], _startPrice());
            vm.prank(STRANGER);
            vm.expectRevert(_gateRevert(abi.encodeWithSelector(SurplusPoolHook.NotInitializer.selector, STRANGER)));
            MANAGER.initialize(rivals[i], _startPrice());
        }
    }

    /// @dev Keys that differ from the official one in exactly one field, plus a native-ETH pair. The first is the
    ///      old 0.30% design and the third the dynamic-fee flag.
    function _rivalKeys() internal view returns (PoolKey[] memory keys) {
        address rivalToken = address(uint160(uint256(keccak256("fork.rival-token"))));
        (address r0, address r1) = rivalToken < WETH ? (rivalToken, WETH) : (WETH, rivalToken);
        keys = new PoolKey[](7);
        keys[0] = PoolKey(official.currency0, official.currency1, 3000, TICK_SPACING, address(hook));
        keys[1] = PoolKey(official.currency0, official.currency1, 10_000, TICK_SPACING, address(hook));
        keys[2] = PoolKey(official.currency0, official.currency1, 0x800000, TICK_SPACING, address(hook));
        keys[3] = PoolKey(official.currency0, official.currency1, LP_FEE, 200, address(hook));
        keys[4] = PoolKey(official.currency0, official.currency1, LP_FEE, 1, address(hook));
        keys[5] = PoolKey(r0, r1, LP_FEE, TICK_SPACING, address(hook));
        keys[6] = PoolKey(address(0), address(v2), LP_FEE, TICK_SPACING, address(hook));
    }
}

contract PoolGateForkV2Currency0Test is PoolGateForkSuite {
    function _v2IsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract PoolGateForkV2Currency1Test is PoolGateForkSuite {
    function _v2IsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
