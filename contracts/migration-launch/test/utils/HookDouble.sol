// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "../../src/LaunchInterfaces.sol";

/**
 * @dev A v4-conformant stand-in for the successor hook (contracts/pool-hook), with the same initializer gate and the
 *      getter the settler checks (INITIALIZER). Setting GATED = false models a hook without the gate. That proves
 *      the settler's own guarantee: a front-run initialization reverts the launch even when the hook does not stop
 *      it. Deploy it, then `vm.etch` its runtime code at an address whose low 14 bits are the flags under test
 *      (0x2000 for the launch); its immutables survive the etch.
 */
contract HookDouble {
    address public immutable INITIALIZER;
    bool public immutable GATED;

    error NotInitializer(address sender);

    constructor(address initializer, bool gated) {
        INITIALIZER = initializer;
        GATED = gated;
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160) external view returns (bytes4) {
        if (GATED && sender != INITIALIZER) revert NotInitializer(sender);
        return HookDouble.beforeInitialize.selector;
    }
}
