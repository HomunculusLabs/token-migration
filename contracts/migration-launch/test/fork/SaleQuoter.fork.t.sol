// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MigrationSettler} from "../../src/MigrationSettler.sol";
import {SaleQuoter} from "../../src/SaleQuoter.sol";
import {IPoolManager, IUniswapV3SwapPool} from "../../src/LaunchInterfaces.sol";
import {LaunchForkBase} from "./LaunchForkBase.sol";
import {LadderMirror} from "../utils/LadderMirror.sol";

interface IV3Slot0 {
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool);
}

/// @dev The kit picks the sale's split from SaleQuoter's quotes (kit/safe_txs.py, sale_split) and then requires the
///      launch simulation to raise exactly the quoted sum. These pin, on the real pools at the pin, that a quote is the
///      settler's own number and that quoting leaves no trace.
contract SaleQuoterForkTest is LaunchForkBase {
    SaleQuoter internal quoter;

    function setUp() public override {
        super.setUp();
        _launchSetup(false, true);
        quoter = new SaleQuoter();
    }

    function test_QuotesAreWhatTheSettlerRaises() public {
        uint256[4] memory tails = [uint256(0), total / 100, total / 10, total / 2];
        for (uint256 i; i < tails.length; ++i) {
            MigrationSettler.Params memory p = _params();
            p.tailIn = tails[i];
            uint256 quoted = _quote(p);
            (uint256 raised,) = _simulate(p);
            assertEq(raised, quoted, "the launch raises exactly the quoted sum");
        }
    }

    function test_AQuoteChangesNothing() public {
        uint256[4] memory before = _poolBalances();
        (uint160 sqrtBefore,) = LadderMirror.slot0(POOL_MANAGER, OLD_POOL_ID);
        (uint160 tailSqrtBefore,,,,,,) = IV3Slot0(V3_TAIL).slot0();

        MigrationSettler.Params memory p = _params();
        _quote(p);

        uint256[4] memory afterS = _poolBalances();
        for (uint256 i; i < 4; ++i) {
            assertEq(afterS[i], before[i], "pool balances unchanged");
        }
        (uint160 sqrtAfter,) = LadderMirror.slot0(POOL_MANAGER, OLD_POOL_ID);
        (uint160 tailSqrtAfter,,,,,,) = IV3Slot0(V3_TAIL).slot0();
        assertEq(sqrtAfter, sqrtBefore, "Doppler price unchanged");
        assertEq(tailSqrtAfter, tailSqrtBefore, "tail price unchanged");
        assertEq(IERC20(WETH).balanceOf(address(quoter)), 0, "the quoter holds no WETH");
        assertEq(IERC20(V1).balanceOf(address(quoter)), 0, "the quoter holds no v1");
    }

    /// @dev The settler refuses a partial fill (V1LeftUnsold), so the kit must see one: a price limit just above the
    ///      tail's price stops the swap early, and the quote says it took less than asked.
    function test_APartialFillShowsAsLessPaid() public {
        (uint160 tailSqrt,,,,,,) = IV3Slot0(V3_TAIL).slot0();
        uint256 asked = total / 10;
        (uint256 wethOut, uint256 paid) = quoter.quoteV3(IUniswapV3SwapPool(V3_TAIL), asked, tailSqrt + tailSqrt / 1000);
        assertTrue(paid != 0 && paid < asked, "a partial fill takes less than asked");
        assertTrue(wethOut != 0, "and pays out what it took");
    }

    /// @dev A swap the pool itself refuses comes back as its own revert, not as a quote.
    function test_ARefusedSwapBubblesUp() public {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "AS"));
        quoter.quoteV3(IUniswapV3SwapPool(V3_TAIL), 0, V3_MAX_SQRT_MINUS_1);
    }

    /// @dev One wei pays out no WETH. The settler refuses that delta, so the quote must too, never report a fill.
    function test_ASwapThatPaysNothingIsRefusedAsTheSettlerRefusesIt() public {
        vm.expectRevert(abi.encodeWithSelector(SaleQuoter.UnexpectedSwapDelta.selector, int256(0), int256(-1)));
        quoter.quoteV4(IPoolManager(POOL_MANAGER), _oldKey(), 1);
    }

    function _quote(MigrationSettler.Params memory p) internal returns (uint256 wethOut) {
        (uint256 doppler, uint256 paid) = quoter.quoteV4(IPoolManager(POOL_MANAGER), p.oldKey, p.v1In - p.tailIn);
        assertEq(paid, p.v1In - p.tailIn, "the Doppler leg fills");
        wethOut = doppler;
        if (p.tailIn != 0) {
            (uint256 tail, uint256 tailPaid) = quoter.quoteV3(IUniswapV3SwapPool(V3_TAIL), p.tailIn, p.tailLimit);
            assertEq(tailPaid, p.tailIn, "the tail leg fills");
            wethOut += tail;
        }
    }

    function _poolBalances() internal view returns (uint256[4] memory b) {
        b[0] = IERC20(WETH).balanceOf(POOL_MANAGER);
        b[1] = IERC20(V1).balanceOf(POOL_MANAGER);
        b[2] = IERC20(WETH).balanceOf(V3_TAIL);
        b[3] = IERC20(V1).balanceOf(V3_TAIL);
    }
}
