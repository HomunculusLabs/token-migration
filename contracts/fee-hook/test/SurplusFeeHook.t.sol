// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SurplusFeeHook} from "../src/SurplusFeeHook.sol";
import {PoolKey, SwapParams} from "../src/V4Minimal.sol";
import {HookTest} from "./utils/HookTest.sol";
import {FlakyToken} from "./utils/FlakyToken.sol";
import {MockPoolManager} from "./utils/MockPoolManager.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Unit suite against a mock PoolManager. The real-manager behaviour lives in test/fork/.
contract SurplusFeeHookTest is HookTest {
    // Spec values, restated independently of the contract's constants.
    uint256 internal constant FEE_PIPS = 15_000; // 1.5%
    uint256 internal constant PIPS = 1_000_000;
    uint24 internal constant LP_FEE = 3000; // pips: 0.30%
    int24 internal constant TICK_SPACING = 60;

    address internal constant TREASURY = address(0x7EA5);
    address internal constant INITIALIZER = address(0x1417);
    address internal constant STRANGER = address(0xBAD);
    address internal constant SWAPPER = address(0x5A1);
    address internal constant TEAM_SINK = address(0x7EA7);
    address internal constant BUYBACK_SINK = address(0xB0B);
    // An output whose 1.5% fee is odd (15e15 + 3), so the split's rounding is observable.
    int128 internal constant ODD_FEE_OUT = 1e18 + 200;

    MockPoolManager internal manager;
    MockERC20 internal token0;
    MockERC20 internal token1;
    SurplusFeeHook internal hook;
    PoolKey internal key;

    function setUp() public {
        manager = new MockPoolManager();
        MockERC20 a = new MockERC20("Token A", "A");
        MockERC20 b = new MockERC20("Token B", "B");
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        hook = _deployHook("unit.hook", _args());
        key = PoolKey(address(token0), address(token1), LP_FEE, TICK_SPACING, address(hook));
        token0.mint(address(manager), 1e30);
        token1.mint(address(manager), 1e30);
    }

    function _args() internal view returns (HookArgs memory) {
        return HookArgs(address(manager), TREASURY, INITIALIZER, address(token0), address(token1), LP_FEE, TICK_SPACING);
    }

    /// @dev Delivers afterSwap as the PoolManager would, with the swap's pre-hook BalanceDelta.
    function _afterSwap(bool zeroForOne, int256 amountSpecified, int128 amount0, int128 amount1)
        internal
        returns (int128 hookDelta)
    {
        vm.prank(address(manager));
        bytes4 selector;
        (selector, hookDelta) =
            hook.afterSwap(SWAPPER, key, SwapParams(zeroForOne, amountSpecified, 0), _delta(amount0, amount1), "");
        assertEq(bytes32(selector), bytes32(SurplusFeeHook.afterSwap.selector), "afterSwap selector");
    }

    function _unwithdrawn(address currency) internal view returns (uint256) {
        return
            (hook.teamOwed(currency) - hook.teamPaid(currency))
                + (hook.buybackOwed(currency) - hook.buybackPaid(currency));
    }

    function test_FeeConstantsMatchSpec() public view {
        assertEq(hook.FEE_PIPS(), FEE_PIPS, "1.5% in pips");
        assertEq(hook.PIPS_DENOMINATOR(), PIPS, "pip denominator");
    }

    function test_AfterSwapRejectsNonManager() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(SurplusFeeHook.NotPoolManager.selector, STRANGER));
        hook.afterSwap(SWAPPER, key, SwapParams(true, -1e18, 0), _delta(-1e18, 2e18), "");
    }

    function test_ExactInZeroForOneChargesToken1() public {
        // 1 token0 in, 2 token1 out: the unspecified currency is the output, token1.
        int128 hookDelta = _afterSwap(true, -1e18, -1e18, 2e18);
        uint256 fee = 2e18 * FEE_PIPS / PIPS;
        assertEq(int256(hookDelta), _int(fee), "hook delta is the fee");
        assertEq(token1.balanceOf(address(hook)), fee, "fee taken in token1");
        assertEq(token0.balanceOf(address(hook)), 0, "nothing taken in token0");
        assertEq(hook.totalTaken(address(token1)), fee, "totalTaken token1");
    }

    function test_ExactInOneForZeroChargesToken0() public {
        // 3 token1 in, 0.5 token0 out: the unspecified currency is the output, token0.
        int128 hookDelta = _afterSwap(false, -3e18, 5e17, -3e18);
        uint256 fee = 5e17 * FEE_PIPS / PIPS;
        assertEq(int256(hookDelta), _int(fee), "hook delta is the fee");
        assertEq(token0.balanceOf(address(hook)), fee, "fee taken in token0");
        assertEq(token1.balanceOf(address(hook)), 0, "nothing taken in token1");
        assertEq(hook.totalTaken(address(token0)), fee, "totalTaken token0");
    }

    function test_H1_ExactOutZeroForOneChargesTheInputToken0() public {
        // 2 token0 in for exactly 1 token1 out: the unspecified currency is the input, token0.
        int128 hookDelta = _afterSwap(true, 1e18, -2e18, 1e18);
        uint256 fee = 2e18 * FEE_PIPS / PIPS;
        assertEq(int256(hookDelta), _int(fee), "hook delta is the fee on the input");
        assertEq(token0.balanceOf(address(hook)), fee, "fee taken in token0, the input");
        assertEq(token1.balanceOf(address(hook)), 0, "nothing taken in token1, the output");
        assertEq(hook.totalTaken(address(token0)), fee, "totalTaken token0");
    }

    function test_H1_ExactOutOneForZeroChargesTheInputToken1() public {
        // 3 token1 in for exactly 0.5 token0 out: the unspecified currency is the input, token1.
        int128 hookDelta = _afterSwap(false, 5e17, 5e17, -3e18);
        uint256 fee = 3e18 * FEE_PIPS / PIPS;
        assertEq(int256(hookDelta), _int(fee), "hook delta is the fee on the input");
        assertEq(token1.balanceOf(address(hook)), fee, "fee taken in token1, the input");
        assertEq(token0.balanceOf(address(hook)), 0, "nothing taken in token0, the output");
        assertEq(hook.totalTaken(address(token1)), fee, "totalTaken token1");
    }

    function test_FeeSplitsIntoHalvesWithTheOddWeiToBuyback() public {
        _afterSwap(true, -1e18, -1e18, ODD_FEE_OUT);
        uint256 fee = _abs(ODD_FEE_OUT) * FEE_PIPS / PIPS;
        assertEq(fee % 2, 1, "fixture fee is odd");
        assertEq(hook.teamOwed(address(token1)), fee / 2, "team half");
        assertEq(hook.buybackOwed(address(token1)), fee - fee / 2, "buyback half keeps the odd wei");
        assertEq(hook.teamOwed(address(token1)) + hook.buybackOwed(address(token1)), fee, "halves sum to the fee");
    }

    function test_WithdrawalsAreTreasuryOnly() public {
        _afterSwap(true, -1e18, -1e18, 2e18);
        address[3] memory outsiders = [STRANGER, INITIALIZER, address(manager)];
        for (uint256 i; i < outsiders.length; ++i) {
            vm.prank(outsiders[i]);
            vm.expectRevert(abi.encodeWithSelector(SurplusFeeHook.NotTreasury.selector, outsiders[i]));
            hook.withdrawTeam(address(token1), outsiders[i], 1);
            vm.prank(outsiders[i]);
            vm.expectRevert(abi.encodeWithSelector(SurplusFeeHook.NotTreasury.selector, outsiders[i]));
            hook.withdrawBuyback(address(token1), outsiders[i], 1);
        }
        assertEq(token1.balanceOf(address(hook)), 2e18 * FEE_PIPS / PIPS, "nothing left the hook");
    }

    function test_OwedAndPaidAreTrackedPerCurrencyAndHalf() public {
        _afterSwap(true, -1e18, -1e18, ODD_FEE_OUT);
        _afterSwap(false, -3e18, 5e17, -3e18);
        uint256 fee1 = _abs(ODD_FEE_OUT) * FEE_PIPS / PIPS;
        uint256 fee0 = 5e17 * FEE_PIPS / PIPS;

        vm.startPrank(TREASURY);
        hook.withdrawTeam(address(token1), TEAM_SINK, 5e15);
        hook.withdrawBuyback(address(token1), BUYBACK_SINK, fee1 - fee1 / 2);
        hook.withdrawTeam(address(token0), TEAM_SINK, fee0 / 2);
        vm.stopPrank();

        assertEq(hook.teamPaid(address(token1)), 5e15, "team paid token1");
        assertEq(hook.buybackPaid(address(token1)), fee1 - fee1 / 2, "buyback paid token1");
        assertEq(hook.teamPaid(address(token0)), fee0 / 2, "team paid token0");
        assertEq(hook.buybackPaid(address(token0)), 0, "buyback token0 untouched");
        assertEq(token1.balanceOf(TEAM_SINK), 5e15, "team sink token1");
        assertEq(token1.balanceOf(BUYBACK_SINK), fee1 - fee1 / 2, "buyback sink token1");
        assertEq(token0.balanceOf(TEAM_SINK), fee0 / 2, "team sink token0");

        // One half's balance can never pay the other half's claim, nor more than its own remainder.
        uint256 teamLeft1 = fee1 / 2 - 5e15;
        vm.prank(TREASURY);
        vm.expectRevert(
            abi.encodeWithSelector(SurplusFeeHook.InsufficientOwed.selector, address(token1), teamLeft1, teamLeft1 + 1)
        );
        hook.withdrawTeam(address(token1), TEAM_SINK, teamLeft1 + 1);
        vm.prank(TREASURY);
        vm.expectRevert(abi.encodeWithSelector(SurplusFeeHook.InsufficientOwed.selector, address(token1), 0, 1));
        hook.withdrawBuyback(address(token1), BUYBACK_SINK, 1);

        // Balance conservation: the hook holds exactly the unwithdrawn owed amounts.
        assertEq(token1.balanceOf(address(hook)), _unwithdrawn(address(token1)), "token1 conserved");
        assertEq(token0.balanceOf(address(hook)), _unwithdrawn(address(token0)), "token0 conserved");
        assertEq(_unwithdrawn(address(token1)), teamLeft1, "only the team remainder is left in token1");
    }

    /// H2: take() needs no sync(), and a currency left synced breaks any native settle later in the same unlock.
    function test_H2_AfterSwapTakesWithoutSyncing() public {
        _afterSwap(true, -1e18, -1e18, 2e18);
        _afterSwap(true, 1e18, -2e18, 1e18);
        assertEq(manager.takeCalls(), 2, "fee taken on each swap");
        assertEq(manager.syncCalls(), 0, "no currency left synced");
    }

    /// H4: a call to an address without code succeeds and returns nothing, so a withdrawal in native ETH
    /// (address(0)) or any other code-less currency would be booked as paid while nothing moved.
    function test_H4_WithdrawalInACurrencyWithoutCodeReverts() public {
        address[2] memory codeless = [address(0), address(0xDEAD0001)];
        vm.deal(address(hook), 1 ether);
        for (uint256 i; i < codeless.length; ++i) {
            _creditOwed(codeless[i], 1 ether);
            vm.startPrank(TREASURY);
            vm.expectRevert(SurplusFeeHook.TransferFailed.selector);
            hook.withdrawTeam(codeless[i], TEAM_SINK, 1 ether);
            vm.expectRevert(SurplusFeeHook.TransferFailed.selector);
            hook.withdrawBuyback(codeless[i], BUYBACK_SINK, 1 ether);
            vm.stopPrank();
            assertEq(hook.teamPaid(codeless[i]), 0, "team half not booked as paid");
            assertEq(hook.buybackPaid(codeless[i]), 0, "buyback half not booked as paid");
        }
    }

    /// H4: a withdrawal to the zero address would burn the fee while booking it as paid.
    function test_H4_WithdrawalToTheZeroAddressReverts() public {
        _afterSwap(true, -1e18, -1e18, 2e18);
        vm.startPrank(TREASURY);
        vm.expectRevert(SurplusFeeHook.ZeroAddress.selector);
        hook.withdrawTeam(address(token1), address(0), 1);
        vm.expectRevert(SurplusFeeHook.ZeroAddress.selector);
        hook.withdrawBuyback(address(token1), address(0), 1);
        vm.stopPrank();
        assertEq(token1.balanceOf(address(0)), 0, "nothing burned");
        assertEq(hook.teamPaid(address(token1)) + hook.buybackPaid(address(token1)), 0, "nothing booked as paid");
    }

    function test_WithdrawalRevertsWhenTheTokenFailsAndBooksNothing() public {
        FlakyToken flaky = new FlakyToken();
        flaky.mint(address(manager), 1e30);
        _accrueIn(address(flaky), 2e18);
        FlakyToken.Mode[2] memory failing = [FlakyToken.Mode.Revert, FlakyToken.Mode.ReturnFalse];
        for (uint256 i; i < failing.length; ++i) {
            flaky.setMode(failing[i]);
            vm.prank(TREASURY);
            vm.expectRevert(SurplusFeeHook.TransferFailed.selector);
            hook.withdrawTeam(address(flaky), TEAM_SINK, 1);
        }
        assertEq(hook.teamPaid(address(flaky)), 0, "nothing booked as paid");

        flaky.setMode(FlakyToken.Mode.ReturnNothing);
        vm.prank(TREASURY);
        hook.withdrawTeam(address(flaky), TEAM_SINK, 1);
        assertEq(flaky.balanceOf(TEAM_SINK), 1, "a token that returns no data still pays");
        assertEq(hook.teamPaid(address(flaky)), 1, "and is booked");
    }

    function test_RejectsNativeEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertFalse(ok, "the hook accepts no native ETH");
    }

    /// Every swap shape pays exactly floor(|unspecified amount| * 1.5%) in the unspecified currency, split into
    /// halves that sum to it, and only through take().
    function testFuzz_ChargesExactlyTheFeeOnTheUnspecifiedCurrency(
        bool zeroForOne,
        bool exactIn,
        uint256 amountIn,
        uint256 amountOut
    ) public {
        // v4 rejects a zero amountSpecified (SwapAmountCannotBeZero), so the specified side is at least 1.
        amountIn = _bound(amountIn, exactIn ? 1 : 0, 1e30);
        amountOut = _bound(amountOut, exactIn ? 0 : 1, 1e30);
        (int128 in_, int128 out_) = (-_i128(amountIn), _i128(amountOut));
        (int128 amount0, int128 amount1) = zeroForOne ? (in_, out_) : (out_, in_);
        int256 amountSpecified = exactIn ? -_int(amountIn) : _int(amountOut);
        // Exact-in leaves the output unspecified, exact-out the input.
        uint256 basis = exactIn ? amountOut : amountIn;
        bool feeIn0 = exactIn != zeroForOne;
        (MockERC20 feeToken, MockERC20 otherToken) = feeIn0 ? (token0, token1) : (token1, token0);

        int128 hookDelta = _afterSwap(zeroForOne, amountSpecified, amount0, amount1);

        uint256 fee = basis * FEE_PIPS / PIPS;
        assertEq(int256(hookDelta), _int(fee), "hook delta is the fee");
        assertEq(feeToken.balanceOf(address(hook)), fee, "fee taken in the unspecified currency");
        assertEq(otherToken.balanceOf(address(hook)), 0, "nothing taken in the specified currency");
        assertEq(hook.totalTaken(address(feeToken)), fee, "totalTaken");
        assertEq(hook.teamOwed(address(feeToken)), fee / 2, "team half");
        assertEq(hook.buybackOwed(address(feeToken)), fee - fee / 2, "buyback half");
        assertEq(manager.takeCalls(), fee == 0 ? 0 : 1, "one take per charged swap");
        assertEq(manager.syncCalls(), 0, "never syncs");
    }

    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        return min + x % (max - min + 1);
    }

    function _i128(uint256 x) internal pure returns (int128) {
        require(x <= uint128(type(int128).max), "int128 overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        return int128(int256(x));
    }

    /// @dev Runs one exact-input swap whose output, and so whose fee, is in `currency`.
    function _accrueIn(address currency, int128 out) internal {
        PoolKey memory k = PoolKey(currency, address(token1), LP_FEE, TICK_SPACING, address(hook));
        vm.prank(address(manager));
        hook.afterSwap(SWAPPER, k, SwapParams(false, -1e18, 0), _delta(out, -1e18), "");
    }

    /// @dev Books `amount` of `currency` to both fee halves without a swap, for currencies no pool can pay in.
    ///      teamOwed and buybackOwed are the hook's first two storage slots: every other field is an immutable.
    function _creditOwed(address currency, uint256 amount) internal {
        vm.store(address(hook), keccak256(abi.encode(currency, uint256(0))), bytes32(amount));
        vm.store(address(hook), keccak256(abi.encode(currency, uint256(1))), bytes32(amount));
        assertEq(hook.teamOwed(currency), amount, "teamOwed slot");
        assertEq(hook.buybackOwed(currency), amount, "buybackOwed slot");
    }
}
