// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HookFlags, PoolKey} from "./V4Minimal.sol";

/// @notice The successor pool's hook, for exactly one pool: the official key fixed at deployment. Its only job is
///         to let the launch helper, and nobody else, create that pool. The PoolManager calls it once, when the
///         pool is initialized, and never again. It charges no fee, so the pool's own LP fee is the only fee a
///         swap pays.
/// @dev    No owner, no funds, no storage. Every launch parameter is an immutable, so it lives in the runtime code:
///         whatever reads or places that code (the launch helper's INITIALIZER() check, the CREATE2 deploy,
///         fork-test etches) sees the parameters without any storage.
contract SurplusPoolHook {
    /// @notice The v4 permission bits the hook's address must carry, and no others. The PoolManager reads
    ///         permissions from the address: without BEFORE_INITIALIZE the gate would silently never run, and any
    ///         other bit would have the manager call the hook on swaps or liquidity changes.
    uint160 public constant REQUIRED_FLAGS = HookFlags.BEFORE_INITIALIZE; // 0x2000
    /// @notice v4's largest static LP fee (LPFeeLibrary.MAX_LP_FEE, 100%).
    uint24 public constant MAX_LP_FEE = 1_000_000;

    address public immutable POOL_MANAGER;
    /// @notice The only account that can initialize the official pool (the launch helper).
    address public immutable INITIALIZER;
    // The official pool key, whose hooks field is this contract.
    address public immutable CURRENCY0;
    address public immutable CURRENCY1;
    uint24 public immutable LP_FEE;
    int24 public immutable TICK_SPACING;

    error InvalidHookAddress(address hook);
    error ZeroAddress();
    error CurrenciesOutOfOrder(address currency0, address currency1);
    error InvalidLpFee(uint24 lpFee);
    error NotPoolManager(address caller);
    error NotInitializer(address sender);
    error UnofficialPoolKey();

    constructor(
        address poolManager,
        address initializer,
        address currency0,
        address currency1,
        uint24 lpFee,
        int24 tickSpacing
    ) {
        if ((uint160(address(this)) & HookFlags.ALL_HOOK_MASK) != REQUIRED_FLAGS) {
            revert InvalidHookAddress(address(this));
        }
        // A zero currency is native ETH, which the official v2/WETH pool does not use.
        if (
            poolManager == address(0) || initializer == address(0) || currency0 == address(0) || currency1 == address(0)
        ) {
            revert ZeroAddress();
        }
        // v4 only accepts keys with currency0 < currency1; any other order names a pool that can never exist.
        if (currency0 >= currency1) revert CurrenciesOutOfOrder(currency0, currency1);
        // Above MAX_LP_FEE is either invalid or the dynamic-fee flag (0x800000). A dynamic-fee pool opens at 0% and
        // only its hook can set a fee, which this hook never does, so the pool would trade for free forever.
        if (lpFee > MAX_LP_FEE) revert InvalidLpFee(lpFee);
        POOL_MANAGER = poolManager;
        INITIALIZER = initializer;
        CURRENCY0 = currency0;
        CURRENCY1 = currency1;
        LP_FEE = lpFee;
        TICK_SPACING = tickSpacing;
    }

    /// @notice v4 BEFORE_INITIALIZE hook. Only the initializer can create a pool naming this hook, and only the
    ///         official key. Otherwise anyone could initialize the official pool first, at a price of their choosing,
    ///         which makes the launch revert, or attach the hook to any other pool.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view returns (bytes4) {
        if (msg.sender != POOL_MANAGER) revert NotPoolManager(msg.sender);
        if (sender != INITIALIZER) revert NotInitializer(sender);
        if (
            key.currency0 != CURRENCY0 || key.currency1 != CURRENCY1 || key.fee != LP_FEE
                || key.tickSpacing != TICK_SPACING || key.hooks != address(this)
        ) revert UnofficialPoolKey();
        return this.beforeInitialize.selector;
    }
}
