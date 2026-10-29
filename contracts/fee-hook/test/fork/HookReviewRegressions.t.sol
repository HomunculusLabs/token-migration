// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey, SwapParams} from "../../src/V4Minimal.sol";
import {ForkHarness} from "./ForkHarness.sol";
import {IPoolManagerErrors} from "./Actor.sol";

/**
 * @dev Regressions for the fee-hook review findings, against the real PoolManager. Expected hook errors are
 *      spelled as signatures, and hook symbols are only used through members every revision has, so the
 *      same file compiles, and fails, against a hook without the fixes.
 */
abstract contract HookReviewRegressionSuite is ForkHarness {
    /// H1: v4 applies the hook's afterSwap delta to the swap's UNSPECIFIED currency, which on an exact-output swap
    /// is the input. Charging the output instead leaves the hook owing one currency and credited in the other.
    function test_H1_ExactOutputSwapsSettleAndChargeTheInput() public {
        _launchBoth();
        _swapAndCheck(_exactOutBuy(25_000 ether));
        _swapAndCheck(_exactOutSell(1 ether));
    }

    /// H3: without a beforeInitialize gate anyone can initialize the official key first, at a price of their
    /// choosing, and any other pool can name the hook.
    function test_H3_OnlyTheInitializerCanInitializeTheOfficialKey() public {
        vm.prank(STRANGER);
        vm.expectRevert(_gateRevert(abi.encodeWithSignature("NotInitializer(address)", STRANGER)));
        MANAGER.initialize(official, _startPrice());
        _launch(official);
        assertGt(uint256(_sqrtPrice(official)), 0, "initializer launched the official pool");
    }

    function test_H3_NoOtherPoolKeyCanNameTheHook() public {
        PoolKey[] memory rivals = _rivalKeys();
        for (uint256 i; i < rivals.length; ++i) {
            vm.prank(INITIALIZER);
            vm.expectRevert(_gateRevert(abi.encodeWithSignature("UnofficialPoolKey()")));
            MANAGER.initialize(rivals[i], _startPrice());
            vm.prank(STRANGER);
            vm.expectRevert(_gateRevert(abi.encodeWithSignature("NotInitializer(address)", STRANGER)));
            MANAGER.initialize(rivals[i], _startPrice());
        }
    }

    /// H2: take() needs no sync(). A currency the hook leaves synced makes any native settle{value:} later in the
    /// same unlock, e.g. a router batch with an ETH leg, revert NonzeroNativeValue.
    function test_H2_NativeSettleLaterInTheSameUnlockSucceeds() public {
        _launch(official);
        SwapParams[4] memory shapes =
            [_exactInBuy(1 ether), _exactInSell(25_000 ether), _exactOutBuy(25_000 ether), _exactOutSell(1 ether)];
        for (uint256 i; i < shapes.length; ++i) {
            uint256 takenBefore = hook.totalTaken(WETH) + hook.totalTaken(address(v2));
            actor.swapThenSettleNative(official, shapes[i]);
            assertGt(hook.totalTaken(WETH) + hook.totalTaken(address(v2)), takenBefore, "the swap was charged");
        }
    }

    /// @dev Keys that differ from the official one in exactly one field, plus a native-ETH pair.
    function _rivalKeys() internal view returns (PoolKey[] memory keys) {
        address rivalToken = address(uint160(uint256(keccak256("fork.rival-token"))));
        (address r0, address r1) = rivalToken < WETH ? (rivalToken, WETH) : (WETH, rivalToken);
        keys = new PoolKey[](6);
        keys[0] = PoolKey(official.currency0, official.currency1, 30, TICK_SPACING, address(hook));
        keys[1] = PoolKey(official.currency0, official.currency1, 10_000, TICK_SPACING, address(hook));
        keys[2] = PoolKey(official.currency0, official.currency1, LP_FEE, 200, address(hook));
        keys[3] = PoolKey(official.currency0, official.currency1, LP_FEE, 1, address(hook));
        keys[4] = PoolKey(r0, r1, LP_FEE, TICK_SPACING, address(hook));
        keys[5] = PoolKey(address(0), address(v2), LP_FEE, TICK_SPACING, address(hook));
    }

    /// @dev How the PoolManager surfaces a reverting beforeInitialize: v4-core CustomRevert.bubbleUpAndRevertWith.
    function _gateRevert(bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            IPoolManagerErrors.WrappedError.selector,
            address(hook),
            bytes4(keccak256("beforeInitialize(address,(address,address,uint24,int24,address),uint160)")),
            reason,
            abi.encodeWithSelector(IPoolManagerErrors.HookCallFailed.selector)
        );
    }
}

contract HookReviewRegressionsV2Currency0Test is HookReviewRegressionSuite {
    function _v2IsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract HookReviewRegressionsV2Currency1Test is HookReviewRegressionSuite {
    function _v2IsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
