// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalanceDeltaLib, ModifyLiquidityParams, SwapParams} from "../../src/V4Minimal.sol";
import {ForkHarness} from "./ForkHarness.sol";

/// @dev The launched pool against the real Base PoolManager at the pinned block, run once per currency order: every
///      swap matches a hookless twin exactly, the only fee is the 1.2% LP fee, and it goes to the position owner.
///      Every shape swaps twice: the second swap proves the first left nothing behind.
abstract contract SurplusPoolHookForkSuite is ForkHarness {
    using BalanceDeltaLib for int256;

    uint256 internal constant Q96 = 1 << 96;

    // What the launch seeded into each pool's position (both pools are seeded identically).
    uint256 internal seededWeth;
    uint256 internal seededV2;

    function setUp() public override {
        super.setUp();
        uint256 wethBefore = IERC20(WETH).balanceOf(address(actor));
        uint256 v2Before = IERC20(address(v2)).balanceOf(address(actor));
        _launchBoth();
        seededWeth = (wethBefore - IERC20(WETH).balanceOf(address(actor))) / 2;
        seededV2 = (v2Before - IERC20(address(v2)).balanceOf(address(actor))) / 2;
    }

    function test_ExactInBuyMatchesTheHooklessPool() public {
        _swapAndCheck(_exactInBuy(1 ether));
        _swapAndCheck(_exactInBuy(1 ether));
    }

    function test_ExactInSellMatchesTheHooklessPool() public {
        _swapAndCheck(_exactInSell(25_000 ether));
        _swapAndCheck(_exactInSell(25_000 ether));
    }

    function test_ExactOutBuyMatchesTheHooklessPool() public {
        _swapAndCheck(_exactOutBuy(25_000 ether));
        _swapAndCheck(_exactOutBuy(25_000 ether));
    }

    function test_ExactOutSellMatchesTheHooklessPool() public {
        _swapAndCheck(_exactOutSell(1 ether));
        _swapAndCheck(_exactOutSell(1 ether));
    }

    /// After initialization the PoolManager never calls the hook again. With the hook's code replaced by an
    /// instruction that always reverts, every swap shape and a liquidity add and remove still go through.
    function test_SwapsAndLiquidityChangesNeverCallTheHook() public {
        vm.etch(address(hook), hex"fe");
        actor.swap(official, _exactInBuy(1 ether));
        actor.swap(official, _exactInSell(25_000 ether));
        actor.swap(official, _exactOutBuy(25_000 ether));
        actor.swap(official, _exactOutSell(1 ether));
        actor.modifyLiquidity(official, ModifyLiquidityParams(lower, upper, 1e20, bytes32(uint256(1))));
        actor.modifyLiquidity(official, ModifyLiquidityParams(lower, upper, -1e20, bytes32(uint256(1))));
    }

    /// Exact-output swaps settle at any size, up to nearly all of a side: nothing is taken from the PoolManager
    /// mid-swap, so there is no threshold past which a swap fails.
    function test_AnExactOutputBuyOfNearlyAllTheV2Settles() public {
        _swapAndCheck(_exactOutBuy(seededV2 * 99 / 100));
    }

    function test_AnExactOutputSellOfNearlyAllTheWethSettles() public {
        _swapAndCheck(_exactOutSell(seededWeth * 99 / 100));
    }

    /// The trader's whole cost on a small trade, against the pool's mid price: the 1.2% LP fee plus a negligible
    /// price impact, and nothing else.
    function test_ASmallTradeCostsTheLpFeeAndNothingElse() public {
        _checkSmallTradeCost("buy 0.01 WETH of v2", _exactInBuy(0.01 ether));
        _checkSmallTradeCost("sell 250 v2 for WETH", _exactInSell(250 ether));
    }

    /// The 1.2% stays in the pool as LP fees, in the currency the trader paid: the position owner collects it.
    function test_TheLpFeeGoesToThePositionOwner() public {
        uint256 wethIn = 2 ether;
        uint256 v2In = 50_000 ether;
        actor.swap(official, _exactInBuy(wethIn));
        actor.swap(official, _exactInSell(v2In));
        // A zero-liquidity modify on the seeded position collects its fees.
        int256 fees = actor.modifyLiquidity(official, ModifyLiquidityParams(lower, upper, 0, 0));
        (int128 wethFees, int128 v2Fees) =
            _v2IsCurrency0() ? (fees.amount1(), fees.amount0()) : (fees.amount0(), fees.amount1());
        _checkCollectedFee("WETH", wethFees, wethIn);
        _checkCollectedFee("v2", v2Fees, v2In);
        _assertHookHoldsNothing();
    }

    function _checkSmallTradeCost(string memory label, SwapParams memory p) internal {
        uint256 atMid = _outputAtMidPrice(p);
        uint256 out = _output(_swapAndCheck(p), p);
        uint256 costPips = (atMid - out) * PIPS / atMid;
        emit log_named_string("trade", label);
        emit log_named_decimal_uint("  trader cost: LP fee + price impact (%)", costPips, 4);
        assertGe(costPips, LP_FEE, "the trade pays the 1.2% LP fee");
        assertLe(costPips, LP_FEE + 10, "and nothing beyond a negligible price impact");
    }

    /// @dev v4 (SwapMath.computeSwapStep) charges an exact-in swap that stays inside one step exactly
    ///      ceil(amountIn × fee / 1e6) and pays it to the position through two floored fee-growth conversions, so the
    ///      owner collects that fee or 1 wei less.
    function _checkCollectedFee(string memory label, int128 collected, uint256 amountIn) internal {
        uint256 fee = (amountIn * LP_FEE + PIPS - 1) / PIPS;
        assertTrue(collected > 0, string.concat(label, ": no LP fee collected"));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 got = uint256(uint128(collected));
        emit log_named_string("collected LP fee", label);
        emit log_named_decimal_uint("  as a share of the trade (%)", got * PIPS * 100 / amountIn, 6);
        assertLe(got, fee, string.concat(label, ": collected more than the 1.2% fee"));
        assertGe(got + 1, fee, string.concat(label, ": collected less than the 1.2% fee"));
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

contract SurplusPoolHookForkV2Currency0Test is SurplusPoolHookForkSuite {
    function _v2IsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract SurplusPoolHookForkV2Currency1Test is SurplusPoolHookForkSuite {
    function _v2IsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
