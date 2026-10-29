// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey, SwapParams} from "../../src/LaunchInterfaces.sol";

/**
 * @dev A stand-in with the real successor hook's constructor
 *      (poolManager, treasury, initializer, currency0, currency1, lpFee, tickSpacing) and its initializer gate,
 *      but no fee. It proved the kit's deploy plan before contracts/fee-hook was integrated. The settler now
 *      refuses it (it has no FEE_PIPS), and the kit no longer falls back to it: it remains as the fee-less hook in
 *      test/fork/OracleReviewLaunch.fork.t.sol.
 */
contract HookStandIn {
    address public immutable POOL_MANAGER;
    address public immutable TREASURY;
    address public immutable INITIALIZER;
    address public immutable CURRENCY0;
    address public immutable CURRENCY1;
    uint24 public immutable LP_FEE;
    int24 public immutable TICK_SPACING;

    error NotInitializer(address sender);
    error NotOfficialKey();

    constructor(
        address poolManager,
        address treasury,
        address initializer,
        address currency0,
        address currency1,
        uint24 lpFee,
        int24 tickSpacing
    ) {
        POOL_MANAGER = poolManager;
        TREASURY = treasury;
        INITIALIZER = initializer;
        CURRENCY0 = currency0;
        CURRENCY1 = currency1;
        LP_FEE = lpFee;
        TICK_SPACING = tickSpacing;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view returns (bytes4) {
        if (sender != INITIALIZER) revert NotInitializer(sender);
        if (
            key.currency0 != CURRENCY0 || key.currency1 != CURRENCY1 || key.fee != LP_FEE
                || key.tickSpacing != TICK_SPACING || key.hooks != address(this)
        ) revert NotOfficialKey();
        return HookStandIn.beforeInitialize.selector;
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, int256, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        return (HookStandIn.afterSwap.selector, 0);
    }
}
