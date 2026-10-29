// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// The slice of the external ABIs the launch settlement touches: the Uniswap v4 PoolManager and
// PositionManager, Permit2, the v3 1% tail pool, and the successor hook's initializer getter. It exists
// so this project needs no Uniswap checkout. Every shape is ABI-identical to the deployed contracts: v4
// `Currency` and `IHooks` are addresses on the wire, and `BalanceDelta` is an int256 (amount0 in the high
// 128 bits, amount1 in the low 128 bits).

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    // Negative = exact input, positive = exact output (v4 convention).
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick);
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IPositionManager {
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// @dev The successor hook's immutables (contracts/fee-hook): its beforeInitialize admits only INITIALIZER, and
///      only for its official PoolKey; it charges FEE_PIPS and only TREASURY can withdraw the fees.
interface ILaunchHook {
    // forge-lint: disable-next-line(mixed-case-function)
    function INITIALIZER() external view returns (address);
    // forge-lint: disable-next-line(mixed-case-function)
    function TREASURY() external view returns (address);
    // forge-lint: disable-next-line(mixed-case-function)
    function FEE_PIPS() external view returns (uint24);
}

/// @dev Uniswap v3 pool swap: a positive amountSpecified is exact input (v3 convention, opposite of v4).
interface IUniswapV3SwapPool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}
