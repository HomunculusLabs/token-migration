// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SurplusFeeHook} from "../../src/SurplusFeeHook.sol";
import {SwapParams} from "../../src/V4Minimal.sol";
import {ForkHarness} from "./ForkHarness.sol";

/// @dev The fee hook against the real Base PoolManager at the pinned block, run once per currency order. Every
///      shape swaps twice: the second swap proves the first left no delta or synced currency behind.
abstract contract SurplusFeeHookForkSuite is ForkHarness {
    uint256 internal constant Q96 = 1 << 96;

    function setUp() public override {
        super.setUp();
        _launchBoth();
    }

    function test_ExactInBuyPaysExactlyTheFee() public {
        _swapAndCheck(_exactInBuy(1 ether));
        _swapAndCheck(_exactInBuy(1 ether));
    }

    function test_ExactInSellPaysExactlyTheFee() public {
        _swapAndCheck(_exactInSell(25_000 ether));
        _swapAndCheck(_exactInSell(25_000 ether));
    }

    function test_ExactOutBuyPaysExactlyTheFee() public {
        _swapAndCheck(_exactOutBuy(25_000 ether));
        _swapAndCheck(_exactOutBuy(25_000 ether));
    }

    function test_ExactOutSellPaysExactlyTheFee() public {
        _swapAndCheck(_exactOutSell(1 ether));
        _swapAndCheck(_exactOutSell(1 ether));
    }

    function test_TreasuryWithdrawsBothHalvesOfEveryFeeCurrency() public {
        _swapAndCheck(_exactInBuy(1 ether));
        _swapAndCheck(_exactInSell(25_000 ether));
        _swapAndCheck(_exactOutBuy(25_000 ether));
        _swapAndCheck(_exactOutSell(1 ether));

        address[2] memory currencies = [WETH, address(v2)];
        for (uint256 i; i < currencies.length; ++i) {
            IERC20 c = IERC20(currencies[i]);
            uint256 team = hook.teamOwed(address(c));
            uint256 buyback = hook.buybackOwed(address(c));
            uint256 held = c.balanceOf(address(hook));
            assertGt(team, 0, "fees accrued in both currencies");
            assertEq(team + buyback, held, "the hook holds exactly the owed fees");
            assertEq(hook.totalTaken(address(c)), held, "and exactly what it took");

            vm.prank(STRANGER);
            vm.expectRevert(abi.encodeWithSelector(SurplusFeeHook.NotTreasury.selector, STRANGER));
            hook.withdrawTeam(address(c), STRANGER, team);

            uint256 teamSinkBefore = c.balanceOf(TEAM_SINK);
            uint256 buybackSinkBefore = c.balanceOf(BUYBACK_SINK);
            vm.startPrank(TREASURY);
            hook.withdrawTeam(address(c), TEAM_SINK, team);
            hook.withdrawBuyback(address(c), BUYBACK_SINK, buyback);
            vm.stopPrank();
            assertEq(c.balanceOf(TEAM_SINK) - teamSinkBefore, team, "team half paid out");
            assertEq(c.balanceOf(BUYBACK_SINK) - buybackSinkBefore, buyback, "buyback half paid out");
            assertEq(c.balanceOf(address(hook)), 0, "hook emptied");
            assertEq(hook.teamPaid(address(c)), team, "team half booked as paid");
            assertEq(hook.buybackPaid(address(c)), buyback, "buyback half booked as paid");
        }
    }

    /// The trader's all-in cost on a small trade, against the pool's mid price: the 0.30% LP fee on the input,
    /// then the 1.5% hook fee on the output, 1 - 0.997 * 0.985 = 1.7955%, plus a negligible price impact.
    function test_AllInCostOfASmallTradeIsAboutOnePointEightPercent() public {
        _checkSmallTradeCost("buy 0.01 WETH of v2", _exactInBuy(0.01 ether));
        _checkSmallTradeCost("sell 250 v2 for WETH", _exactInSell(250 ether));
    }

    function _checkSmallTradeCost(string memory label, SwapParams memory p) internal {
        uint256 atMid = _outputAtMidPrice(p);
        int256 control = actor.swap(twin, p);
        int256 charged = actor.swap(official, p);
        uint256 hooklessOut = _abs(_unspecified(control, p));
        uint256 chargedOut = _abs(_unspecified(charged, p));

        uint256 lpAndImpactPips = (atMid - hooklessOut) * PIPS / atMid;
        uint256 hookPips = (hooklessOut - chargedOut) * PIPS / hooklessOut;
        uint256 allInPips = (atMid - chargedOut) * PIPS / atMid;
        emit log_named_string("trade", label);
        emit log_named_decimal_uint("  LP fee + price impact (%)", lpAndImpactPips, 4);
        emit log_named_decimal_uint("  hook fee (%)", hookPips, 4);
        emit log_named_decimal_uint("  all-in trader cost (%)", allInPips, 4);
        assertGe(lpAndImpactPips, 3000, "LP fee is 0.30%");
        assertLe(lpAndImpactPips, 3010, "price impact is negligible");
        assertGe(hookPips, 14_999, "hook fee is 1.5%, floored");
        assertLe(hookPips, 15_000, "hook fee is at most 1.5%");
        assertGe(allInPips, 17_955, "all-in cost is at least 1 - 0.997 * 0.985");
        assertLe(allInPips, 17_965, "all-in cost is about 1.8%");
    }

    /// @dev The exact-input swap's output at the current mid price, with no fee and no price impact.
    function _outputAtMidPrice(SwapParams memory p) internal view returns (uint256) {
        uint256 amountIn = _abs(p.amountSpecified);
        uint256 sqrtPrice = _sqrtPrice(official);
        assertEq(sqrtPrice, uint256(_sqrtPrice(twin)), "twin at the same price");
        // price = sqrtPrice^2 / 2^192, in currency1 per currency0.
        return
            p.zeroForOne ? amountIn * sqrtPrice / Q96 * sqrtPrice / Q96 : amountIn * Q96 / sqrtPrice * Q96 / sqrtPrice;
    }
}

contract SurplusFeeHookForkV2Currency0Test is SurplusFeeHookForkSuite {
    function _v2IsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract SurplusFeeHookForkV2Currency1Test is SurplusFeeHookForkSuite {
    function _v2IsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
