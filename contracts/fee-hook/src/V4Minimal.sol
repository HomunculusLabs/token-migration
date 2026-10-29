// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// The slice of the Uniswap v4-core 1.0.x ABI that the fee hook and its launch path touch, so neither
// project needs a v4-core checkout. Every shape is ABI-identical to v4-core's: `Currency` and `IHooks`
// are addresses on the wire and `BalanceDelta` is an int256 (amount0 in the high 128 bits, amount1 in
// the low 128 bits), so selectors and encodings match what the deployed PoolManager sends and expects.

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    // Negative = exact input, positive = exact output.
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick);
    function modifyLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData)
        external
        returns (int256 callerDelta, int256 feesAccrued);
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32 value);
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @dev v4-core Hooks.sol permission bits. The PoolManager reads a hook's permissions from the low 14
///      bits of its ADDRESS, so they are fixed when the address is chosen (CREATE2 salt), never later.
library HookFlags {
    uint160 internal constant ALL_HOOK_MASK = (1 << 14) - 1;
    uint160 internal constant BEFORE_INITIALIZE = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE = 1 << 12;
    uint160 internal constant BEFORE_ADD_LIQUIDITY = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY = 1 << 10;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY = 1 << 8;
    uint160 internal constant BEFORE_SWAP = 1 << 7;
    uint160 internal constant AFTER_SWAP = 1 << 6;
    uint160 internal constant BEFORE_DONATE = 1 << 5;
    uint160 internal constant AFTER_DONATE = 1 << 4;
    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURNS_DELTA = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA = 1 << 0;
}

/// @dev Unpacks a v4 BalanceDelta. Both halves are int128 by construction, so the truncating casts are exact.
library BalanceDeltaLib {
    function amount0(int256 delta) internal pure returns (int128) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return int128(delta >> 128);
    }

    function amount1(int256 delta) internal pure returns (int128) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return int128(delta);
    }
}
