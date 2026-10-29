// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev Stands in for the v4 PoolManager in unit tests: hook callbacks are pranked from its address, and
 *      take() pays out of the mock's own token balance, as the real manager pays out of its reserves.
 *      sync() only counts, so a test can pin that the hook never leaves a currency synced.
 */
contract MockPoolManager {
    uint256 public syncCalls;
    uint256 public takeCalls;

    function sync(address) external {
        syncCalls++;
    }

    function take(address currency, address to, uint256 amount) external {
        takeCalls++;
        require(IERC20(currency).transfer(to, amount), "take transfer");
    }
}
