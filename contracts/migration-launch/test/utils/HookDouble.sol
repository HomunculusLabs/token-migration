// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey, SwapParams} from "../../src/LaunchInterfaces.sol";

/**
 * @dev A v4-conformant stand-in for the successor hook (contracts/fee-hook), with the same initializer gate
 *      and the same getters the settler checks (INITIALIZER, TREASURY, FEE_PIPS), but no fee taken. Setting
 *      GATED = false models a hook without the gate. That proves the settler's own guarantee: a front-run
 *      initialization reverts the launch even when the hook does not stop it. Deploy it, then `vm.etch` its
 *      runtime code at an address whose low 14 bits are 0x2044; its immutables survive the etch.
 */
contract HookDouble {
    uint24 public constant FEE_PIPS = 15_000;
    address public immutable INITIALIZER;
    address public immutable TREASURY;
    bool public immutable GATED;

    error NotInitializer(address sender);

    constructor(address initializer, address treasury, bool gated) {
        INITIALIZER = initializer;
        TREASURY = treasury;
        GATED = gated;
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160) external view returns (bytes4) {
        if (GATED && sender != INITIALIZER) revert NotInitializer(sender);
        return HookDouble.beforeInitialize.selector;
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, int256, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        return (HookDouble.afterSwap.selector, 0);
    }
}
