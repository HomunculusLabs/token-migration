// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager, IUnlockCallback, IUniswapV3SwapPool, PoolKey, SwapParams} from "./LaunchInterfaces.sol";
import {LaunchMath} from "./LaunchMath.sol";

/**
 * @title SaleQuoter
 * @notice Quotes each leg of MigrationSettler's sale exactly as `settle` swaps it: v1 in, exact input, the same price
 *         limits and sign checks, no hook data. The launch kit (kit/safe_txs.py) runs it only inside eth_call on its
 *         private fork, to choose how much v1 to sell on the v3 tail. It is never deployed: every quote reverts in the
 *         swap callback, so it pays nothing, holds nothing and changes no state.
 *
 * - A quote returns what the swap would pay out (`wethOut`) and take (`v1Paid`). `v1Paid` below the amount asked is a
 *   partial fill, which the settler refuses (V1LeftUnsold).
 * - Any other revert (a delta the settler would refuse, a hook error) bubbles up: the settler would revert there too.
 */
contract SaleQuoter is IUnlockCallback {
    using SafeCast for uint256;

    /// @dev v4 TickMath.MAX_SQRT_PRICE - 1, the settler's limit for the v4 leg.
    uint160 internal constant MAX_SQRT_PRICE_MINUS_1 = 1461446703485210103287273052203988822378723970341;

    error Quote(uint256 wethOut, uint256 v1Paid);
    error UnexpectedSwapDelta(int256 amount0, int256 amount1);
    error NoQuote();

    /// @notice The v4 leg: `v1In` sold on `key` (currency0 WETH, currency1 v1) through `poolManager`.
    function quoteV4(IPoolManager poolManager, PoolKey calldata key, uint256 v1In)
        external
        returns (uint256 wethOut, uint256 v1Paid)
    {
        try poolManager.unlock(abi.encode(key, v1In)) {
            revert NoQuote();
        } catch (bytes memory reason) {
            return _quoted(reason);
        }
    }

    /// @notice The v3 leg: `v1In` (token1) sold on `pool` for WETH (token0) up to `sqrtPriceLimitX96`.
    function quoteV3(IUniswapV3SwapPool pool, uint256 v1In, uint160 sqrtPriceLimitX96)
        external
        returns (uint256 wethOut, uint256 v1Paid)
    {
        try pool.swap(address(this), false, v1In.toInt256(), sqrtPriceLimitX96, bytes("")) {
            revert NoQuote();
        } catch (bytes memory reason) {
            return _quoted(reason);
        }
    }

    /// @dev The settler's v4 sale callback up to the point where it pays: the same swap and the same sign check.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 v1In) = abi.decode(data, (PoolKey, uint256));
        int256 delta =
            IPoolManager(msg.sender).swap(key, SwapParams(false, -v1In.toInt256(), MAX_SQRT_PRICE_MINUS_1), bytes(""));
        int128 wethOut = LaunchMath.amount0(delta);
        int128 v1Paid = LaunchMath.amount1(delta);
        if (wethOut <= 0 || v1Paid >= 0) revert UnexpectedSwapDelta(wethOut, v1Paid);
        // Both casts are exact: wethOut > 0 and v1Paid < 0 were checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        revert Quote(uint256(uint128(wethOut)), uint256(uint128(-v1Paid)));
    }

    /// @dev The settler's v3 sale callback up to the point where it pays: the same sign check.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external pure {
        if (amount1Delta <= 0 || amount0Delta > 0) revert UnexpectedSwapDelta(amount0Delta, amount1Delta);
        // Both casts are exact: amount0Delta <= 0 and amount1Delta > 0 were checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        revert Quote(uint256(-amount0Delta), uint256(amount1Delta));
    }

    /// @dev A Quote is its selector and two words; any other revert is the swap's own, passed on unchanged.
    function _quoted(bytes memory reason) private pure returns (uint256 wethOut, uint256 v1Paid) {
        // bytes4 keeps the first four bytes, the selector, which is the point.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (reason.length != 68 || bytes4(reason) != Quote.selector) {
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
        assembly ("memory-safe") {
            wethOut := mload(add(reason, 36))
            v1Paid := mload(add(reason, 68))
        }
    }
}
