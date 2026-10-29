// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "../Base.t.sol";
import {SurplusFeeHook} from "../../src/SurplusFeeHook.sol";
import {HookFlags} from "../../src/V4Minimal.sol";

/**
 * @dev Deploys the hook where the PoolManager requires it: at an address whose low 14 bits equal the
 *      permissions the hook declares. Production mines a CREATE2 salt for that; tests etch the creation
 *      code at a crafted address and call it, so the constructor runs AT that address and sees it, then
 *      etch the runtime it returns. Immutables live in that runtime, so they survive the etch.
 */
abstract contract HookTest is Test {
    /// @dev The hook's constructor arguments, in order.
    struct HookArgs {
        address poolManager;
        address treasury;
        address initializer;
        address currency0;
        address currency1;
        uint24 lpFee;
        int24 tickSpacing;
    }

    function _hookInitCode(HookArgs memory a) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(SurplusFeeHook).creationCode,
            abi.encode(a.poolManager, a.treasury, a.initializer, a.currency0, a.currency1, a.lpFee, a.tickSpacing)
        );
    }

    /// @dev The permission bits the compiled hook declares.
    function _declaredFlags() internal returns (uint160) {
        address probe = address(uint160(uint256(keccak256("fee-hook.declared-flags"))));
        vm.etch(probe, vm.getDeployedCode("SurplusFeeHook.sol:SurplusFeeHook"));
        return SurplusFeeHook(probe).REQUIRED_FLAGS();
    }

    /// @dev A deterministic address derived from `seed` whose low 14 bits are exactly `flags`.
    function _flaggedAddress(string memory seed, uint160 flags) internal pure returns (address) {
        return address((uint160(uint256(keccak256(bytes(seed)))) & ~HookFlags.ALL_HOOK_MASK) | flags);
    }

    /// @dev Runs `initCode` at `at`; on success `at` then holds the runtime code the constructor returned.
    function _constructAt(address at, bytes memory initCode) internal returns (bool ok, bytes memory ret) {
        vm.etch(at, initCode);
        (ok, ret) = at.call("");
        if (ok) vm.etch(at, ret);
    }

    function _deployAt(address at, bytes memory initCode) internal {
        (bool ok, bytes memory ret) = _constructAt(at, initCode);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _deployHook(string memory seed, HookArgs memory a) internal returns (SurplusFeeHook hook) {
        hook = SurplusFeeHook(_flaggedAddress(seed, _declaredFlags()));
        _deployAt(address(hook), _hookInitCode(a));
        vm.label(address(hook), seed);
    }

    /// @dev v4-core toBalanceDelta: amount0 in the high 128 bits, amount1 in the low 128 bits.
    function _delta(int128 amount0, int128 amount1) internal pure returns (int256 d) {
        assembly ("memory-safe") {
            d := or(shl(128, amount0), and(sub(shl(128, 1), 1), amount1))
        }
    }

    function _abs(int256 x) internal pure returns (uint256) {
        // Both branches are non-negative, so the sign-changing casts are exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        return x < 0 ? uint256(-x) : uint256(x);
    }

    function _int(uint256 x) internal pure returns (int256) {
        require(x <= uint256(type(int256).max), "int256 overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(x);
    }
}
