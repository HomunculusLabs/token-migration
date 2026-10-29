// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    BalanceDeltaLib,
    IPoolManager,
    IUnlockCallback,
    ModifyLiquidityParams,
    PoolKey,
    SwapParams
} from "../../src/V4Minimal.sol";

/// @dev v4-core errors the fork suites expect, declared so forge decodes them in failure output.
interface IPoolManagerErrors {
    error CurrencyNotSettled();
    error NonzeroNativeValue();
    error HookAddressNotValid(address hooks);
    error PoolAlreadyInitialized();
    error HookCallFailed();
    error WrappedError(address target, bytes4 selector, bytes reason, bytes details);
}

/**
 * @dev Generic v4 actor: modifies liquidity or swaps inside one unlock, then settles every delta the way
 *      the v4 routers do (sync + transfer + settle to pay an ERC-20, take to collect). Holds the tokens it
 *      trades.
 */
contract Actor is IUnlockCallback {
    using BalanceDeltaLib for int256;

    enum Op {
        ModifyLiquidity,
        Swap,
        SwapThenSettleNative
    }

    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function modifyLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params) external returns (int256) {
        return _run(Op.ModifyLiquidity, key, abi.encode(params));
    }

    /// @return delta The swapper's BalanceDelta, i.e. after the hook's return delta is applied.
    function swap(PoolKey calldata key, SwapParams calldata params) external returns (int256 delta) {
        return _run(Op.Swap, key, abi.encode(params));
    }

    /// @dev A swap followed, in the same unlock, by a native settle{value:} and take: what a router batch with an
    ///      ETH leg does. A native settle carries no sync(), so it reverts NonzeroNativeValue if the swap left any
    ///      ERC-20 synced.
    function swapThenSettleNative(PoolKey calldata key, SwapParams calldata params) external returns (int256) {
        return _run(Op.SwapThenSettleNative, key, abi.encode(params));
    }

    function _run(Op op, PoolKey memory key, bytes memory args) internal returns (int256) {
        return abi.decode(manager.unlock(abi.encode(op, key, args)), (int256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (Op op, PoolKey memory key, bytes memory args) = abi.decode(data, (Op, PoolKey, bytes));
        int256 delta;
        if (op == Op.ModifyLiquidity) {
            (delta,) = manager.modifyLiquidity(key, abi.decode(args, (ModifyLiquidityParams)), "");
        } else {
            delta = manager.swap(key, abi.decode(args, (SwapParams)), "");
        }
        if (op == Op.SwapThenSettleNative) {
            manager.settle{value: 1}();
            manager.take(address(0), address(this), 1);
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(address currency, int128 amount) internal {
        if (amount < 0) {
            // amount < 0, so the negation is positive and fits in uint128.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 owed = uint256(uint128(-amount));
            manager.sync(currency);
            require(IERC20(currency).transfer(address(manager), owed), "pay");
            manager.settle();
        } else if (amount > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}
