// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SurplusFeeHook} from "../src/SurplusFeeHook.sol";
import {HookMiner} from "./HookMiner.sol";

/// @dev The cheatcodes this script uses (no forge-std in this monorepo).
interface ScriptVm {
    function envAddress(string calldata name) external view returns (address);
    function envOr(string calldata name, address defaultValue) external view returns (address);
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256);
    function envOr(string calldata name, int256 defaultValue) external view returns (int256);
    function envOr(string calldata name, string calldata defaultValue) external view returns (string memory);
    function etch(address target, bytes calldata code) external;
    function serializeAddress(string calldata objectKey, string calldata valueKey, address value)
        external
        returns (string memory);
    function serializeBytes32(string calldata objectKey, string calldata valueKey, bytes32 value)
        external
        returns (string memory);
    function serializeUint(string calldata objectKey, string calldata valueKey, uint256 value)
        external
        returns (string memory);
    function serializeInt(string calldata objectKey, string calldata valueKey, int256 value)
        external
        returns (string memory);
    function serializeString(string calldata objectKey, string calldata valueKey, string calldata value)
        external
        returns (string memory);
    function toString(bytes calldata value) external pure returns (string memory);
    function createDir(string calldata path, bool recursive) external;
    function writeJson(string calldata json, string calldata path) external;
}

/**
 * @title MineHookSalt
 * @notice Mines the CREATE2 salt that deploys SurplusFeeHook at an address whose low 14 bits are exactly its
 *         permission flags (0x2044), and writes {deployer, salt, address, initCodeHash, flags, constructorArgs}
 *         as JSON. Pure local computation: no RPC, no broadcast, nothing to sign.
 *
 *         ENV    HOOK_TREASURY, HOOK_INITIALIZER, HOOK_CURRENCY0, HOOK_CURRENCY1   required
 *                HOOK_POOL_MANAGER   default: the Base v4 PoolManager
 *                HOOK_LP_FEE         default: 3000 pips (0.30%)
 *                HOOK_TICK_SPACING   default: 60
 *                HOOK_DEPLOYER       default: Arachnid's CREATE2 proxy
 *                HOOK_SALT_START     default: 0; the result is the smallest matching salt from here upward
 *                HOOK_SALT_OUT       default: output/hook-salt.json
 *
 *         Deploy by sending calldata salt ++ initCode to the deployer, where initCode = the hook's creation code
 *         (pinned build) ++ abi.encode(constructor args); its keccak256 must equal the recorded initCodeHash.
 */
contract MineHookSalt {
    ScriptVm internal constant vm = ScriptVm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address internal constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    /// @notice SurplusFeeHook.REQUIRED_FLAGS: BEFORE_INITIALIZE | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA.
    uint160 public constant HOOK_FLAGS = 0x2044;

    /// @dev Script stdout: forge prints these DSTest-style events under `== Logs ==`.
    event log_named_address(string key, address val);
    event log_named_bytes32(string key, bytes32 val);

    struct Args {
        address poolManager;
        address treasury;
        address initializer;
        address currency0;
        address currency1;
        uint24 lpFee;
        int24 tickSpacing;
    }

    error ArgOutOfRange(string name);
    error WrongFlags(address hook);

    function run() external returns (bytes32 salt, address hook) {
        Args memory a = _args();
        address deployer = vm.envOr("HOOK_DEPLOYER", HookMiner.CREATE2_DEPLOYER);
        bytes memory initCode = initCodeFor(a);
        bytes32 initCodeHash = keccak256(initCode);
        (salt, hook) = HookMiner.find(
            deployer, initCodeHash, HOOK_FLAGS, vm.envOr("HOOK_SALT_START", uint256(0)), HookMiner.MAX_ITERATIONS
        );
        if ((uint160(hook) & 0x3FFF) != HOOK_FLAGS) revert WrongFlags(hook);
        _dryRunConstructor(hook, initCode);
        _write(vm.envOr("HOOK_SALT_OUT", string("output/hook-salt.json")), deployer, salt, hook, initCodeHash, a);

        emit log_named_address("deployer", deployer);
        emit log_named_bytes32("salt", salt);
        emit log_named_address("hook", hook);
        emit log_named_bytes32("initCodeHash", initCodeHash);
    }

    function initCodeFor(Args memory a) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(SurplusFeeHook).creationCode,
            abi.encode(a.poolManager, a.treasury, a.initializer, a.currency0, a.currency1, a.lpFee, a.tickSpacing)
        );
    }

    function _args() internal view returns (Args memory a) {
        a.poolManager = vm.envOr("HOOK_POOL_MANAGER", BASE_POOL_MANAGER);
        a.treasury = vm.envAddress("HOOK_TREASURY");
        a.initializer = vm.envAddress("HOOK_INITIALIZER");
        a.currency0 = vm.envAddress("HOOK_CURRENCY0");
        a.currency1 = vm.envAddress("HOOK_CURRENCY1");
        uint256 lpFee = vm.envOr("HOOK_LP_FEE", uint256(3000));
        int256 tickSpacing = vm.envOr("HOOK_TICK_SPACING", int256(60));
        if (lpFee > type(uint24).max) revert ArgOutOfRange("HOOK_LP_FEE");
        if (tickSpacing < type(int24).min || tickSpacing > type(int24).max) revert ArgOutOfRange("HOOK_TICK_SPACING");
        // Both bounds checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        (a.lpFee, a.tickSpacing) = (uint24(lpFee), int24(tickSpacing));
    }

    /// @dev Runs the constructor AT the mined address, where it sees the same address(this) as the real
    ///      deployment, so arguments it would reject (zero addresses, unsorted currencies, wrong flags) fail
    ///      here rather than in a signed deploy. Local simulation only: the etched code never leaves the script.
    function _dryRunConstructor(address hook, bytes memory initCode) internal {
        vm.etch(hook, initCode);
        (bool ok, bytes memory reason) = hook.call("");
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    function _write(
        string memory path,
        address deployer,
        bytes32 salt,
        address hook,
        bytes32 initCodeHash,
        Args memory a
    ) internal {
        vm.serializeAddress("constructorArgs", "poolManager", a.poolManager);
        vm.serializeAddress("constructorArgs", "treasury", a.treasury);
        vm.serializeAddress("constructorArgs", "initializer", a.initializer);
        vm.serializeAddress("constructorArgs", "currency0", a.currency0);
        vm.serializeAddress("constructorArgs", "currency1", a.currency1);
        vm.serializeUint("constructorArgs", "lpFee", a.lpFee);
        string memory args = vm.serializeInt("constructorArgs", "tickSpacing", a.tickSpacing);

        vm.serializeAddress("hookSalt", "deployer", deployer);
        vm.serializeBytes32("hookSalt", "salt", salt);
        vm.serializeAddress("hookSalt", "address", hook);
        vm.serializeBytes32("hookSalt", "initCodeHash", initCodeHash);
        // The address's 14 flag bits, rendered as two bytes ("0x2044").
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 flagBits = uint16(uint160(hook) & 0x3FFF);
        vm.serializeString("hookSalt", "flags", vm.toString(abi.encodePacked(flagBits)));
        // fs_permissions confine writes to ./output, which is git-ignored and so absent on a fresh checkout.
        vm.createDir("output", true);
        vm.writeJson(vm.serializeString("hookSalt", "constructorArgs", args), path);
    }
}
