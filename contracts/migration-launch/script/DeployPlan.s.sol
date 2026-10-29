// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MigrationVault} from "@surplus/migration/src/MigrationVault.sol";
import {SurplusTokenV2} from "@surplus/token-v2/src/SurplusTokenV2.sol";
import {MigrationSettler} from "../src/MigrationSettler.sol";

interface IDeployVm {
    struct EthGetLogs {
        address emitter;
        bytes32[] topics;
        bytes data;
        bytes32 blockHash;
        uint64 blockNumber;
        bytes32 transactionHash;
        uint64 transactionIndex;
        uint256 logIndex;
        bool removed;
    }

    function readFile(string calldata path) external view returns (string memory);
    function writeFile(string calldata path, string calldata data) external;
    function parseJsonAddress(string calldata json, string calldata key) external pure returns (address);
    function parseJsonAddressArray(string calldata json, string calldata key) external pure returns (address[] memory);
    function parseJsonUint(string calldata json, string calldata key) external pure returns (uint256);
    function parseJsonInt(string calldata json, string calldata key) external pure returns (int256);
    function parseJsonString(string calldata json, string calldata key) external pure returns (string memory);
    function parseJsonBytes32(string calldata json, string calldata key) external pure returns (bytes32);
    function parseJsonBytes(string calldata json, string calldata key) external pure returns (bytes memory);
    function parseJsonBool(string calldata json, string calldata key) external pure returns (bool);
    function envString(string calldata name) external view returns (string memory);
    function serializeAddress(string calldata objectKey, string calldata valueKey, address value)
        external
        returns (string memory);
    function serializeBytes32(string calldata objectKey, string calldata valueKey, bytes32 value)
        external
        returns (string memory);
    function serializeBytes(string calldata objectKey, string calldata valueKey, bytes calldata value)
        external
        returns (string memory);
    function serializeUint(string calldata objectKey, string calldata valueKey, uint256 value)
        external
        returns (string memory);
    function serializeString(string calldata objectKey, string calldata valueKey, string calldata value)
        external
        returns (string memory);
    function toString(address value) external pure returns (string memory);
}

interface ISafeProxyFactory141 {
    function proxyCreationCode() external pure returns (bytes memory);
}

interface ISafe141Setup {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
}

/**
 * @title DeployPlan
 * @notice Launch kit phase "deploy-plan": computes, WITHOUT broadcasting, every address and init code the
 *         launch deploys, in deploy order: the Safe 1.4.1 proxy (factory CREATE2 over its setup data), the v2
 *         implementation and its ERC1967 proxy, the vault and the settler (all through the canonical CREATE2
 *         deployer), and the successor hook (salt mined so its address carries exactly the 0x2044 flags).
 *         Everything is a pure function of the resolved params and the compiler output, so anyone can
 *         recompute it. It never calls vm.broadcast.
 * @dev    Input: kit/output/deploy/resolved.json, written by kit/deploy_plan.py after it has checked every
 *         param this phase needs is decided. Output: kit/output/deploy/plan.json.
 */
contract DeployPlan {
    IDeployVm internal constant vm = IDeployVm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint160 internal constant HOOK_FLAGS = 0x2044;
    uint160 internal constant ALL_HOOK_MASK = (1 << 14) - 1;
    /// @dev The hook salt search is bounded so a wrong flag set fails in seconds rather than spinning.
    uint256 internal constant MAX_HOOK_SALTS = 2_000_000;

    struct Addresses {
        address safe;
        address tokenImplementation;
        address token;
        address vault;
        address settler;
        address hook;
    }

    struct InitCodes {
        bytes safeInitializer;
        bytes implementation;
        bytes tokenProxy;
        bytes vault;
        bytes settler;
        bytes hook;
        bytes32 hookSalt;
    }

    function run() external {
        string memory p = vm.readFile("kit/output/deploy/resolved.json");
        address deployer = vm.parseJsonAddress(p, ".create2Deployer");
        Addresses memory a;
        InitCodes memory c;
        (a.safe, c.safeInitializer) = _safe(p);

        c.implementation = type(SurplusTokenV2).creationCode;
        a.tokenImplementation =
            _create2(deployer, vm.parseJsonBytes32(p, ".salts.tokenImplementation"), c.implementation);
        c.tokenProxy = _proxyInit(p, a);
        a.token = _create2(deployer, vm.parseJsonBytes32(p, ".salts.tokenProxy"), c.tokenProxy);
        c.vault = _vaultInit(p, a);
        a.vault = _create2(deployer, vm.parseJsonBytes32(p, ".salts.vault"), c.vault);
        c.settler = _settlerInit(p, a);
        a.settler = _create2(deployer, vm.parseJsonBytes32(p, ".salts.settler"), c.settler);
        (c.hook, c.hookSalt) = _hook(p, a, deployer);
        a.hook = _create2(deployer, c.hookSalt, c.hook);
        _write(p, a, c);
    }

    function _write(string memory p, Addresses memory a, InitCodes memory c) internal {
        string memory o = "plan";
        vm.serializeAddress(o, "safe", a.safe);
        vm.serializeBytes32(o, "safeInitializerHash", keccak256(c.safeInitializer));
        vm.serializeAddress(o, "tokenImplementation", a.tokenImplementation);
        vm.serializeBytes32(o, "tokenImplementationInitCodeHash", keccak256(c.implementation));
        vm.serializeAddress(o, "token", a.token);
        vm.serializeBytes32(o, "tokenProxyInitCodeHash", keccak256(c.tokenProxy));
        vm.serializeAddress(o, "vault", a.vault);
        vm.serializeBytes32(o, "vaultInitCodeHash", keccak256(c.vault));
        vm.serializeAddress(o, "settler", a.settler);
        vm.serializeBytes32(o, "settlerInitCodeHash", keccak256(c.settler));
        vm.serializeAddress(o, "hook", a.hook);
        vm.serializeBytes32(o, "hookSalt", c.hookSalt);
        vm.serializeBytes32(o, "hookInitCodeHash", keccak256(c.hook));
        vm.serializeBytes(o, "safeInitializer", c.safeInitializer);
        vm.serializeBytes(o, "tokenImplementationInitCode", c.implementation);
        vm.serializeBytes(o, "tokenProxyInitCode", c.tokenProxy);
        vm.serializeBytes(o, "vaultInitCode", c.vault);
        vm.serializeBytes(o, "settlerInitCode", c.settler);
        vm.serializeBytes(o, "hookInitCode", c.hook);
        vm.serializeBytes(o, "tokenProxyConstructorArgs", _tail(c.tokenProxy, type(ERC1967Proxy).creationCode.length));
        vm.serializeBytes(o, "vaultConstructorArgs", _tail(c.vault, type(MigrationVault).creationCode.length));
        vm.serializeBytes(o, "settlerConstructorArgs", _tail(c.settler, type(MigrationSettler).creationCode.length));
        string memory json = vm.serializeBytes(
            o, "hookConstructorArgs", _tail(c.hook, vm.parseJsonBytes(p, ".hook.creationCode").length)
        );
        vm.writeFile("kit/output/deploy/plan.json", json);
    }

    /// @dev Safe 1.4.1 SafeProxyFactory.createProxyWithNonce: salt = keccak(keccak(initializer) ‖ saltNonce),
    ///      init code = proxyCreationCode ‖ uint256(singleton).
    function _safe(string memory p) internal pure returns (address safe, bytes memory initializer) {
        address factory = vm.parseJsonAddress(p, ".safe141.proxyFactory");
        address singleton = vm.parseJsonAddress(p, ".safe141.singleton");
        initializer = abi.encodeCall(
            ISafe141Setup.setup,
            (
                vm.parseJsonAddressArray(p, ".governance.owners"),
                vm.parseJsonUint(p, ".governance.threshold"),
                address(0),
                bytes(""),
                address(0),
                address(0),
                0,
                payable(address(0))
            )
        );
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), vm.parseJsonUint(p, ".governance.saltNonce")));
        bytes memory init =
            abi.encodePacked(ISafeProxyFactory141(factory).proxyCreationCode(), uint256(uint160(singleton)));
        safe = _create2(factory, salt, init);
    }

    function _proxyInit(string memory p, Addresses memory a) internal pure returns (bytes memory) {
        bytes memory init = abi.encodeCall(
            SurplusTokenV2.initialize,
            (
                vm.parseJsonString(p, ".token.name"),
                vm.parseJsonString(p, ".token.symbol"),
                vm.parseJsonUint(p, ".token.capWei"),
                a.safe
            )
        );
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(a.tokenImplementation, init));
    }

    function _vaultInit(string memory p, Addresses memory a) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(MigrationVault).creationCode,
            abi.encode(
                IERC20(vm.parseJsonAddress(p, ".v1")),
                IERC20(a.token),
                vm.parseJsonUint(p, ".vault.depositDeadline"),
                vm.parseJsonUint(p, ".vault.commitDeadline"),
                vm.parseJsonUint(p, ".vault.executionWindowSeconds"),
                vm.parseJsonUint(p, ".vault.claimPeriodSeconds"),
                vm.parseJsonUint(p, ".vault.rateBps"),
                vm.parseJsonBool(p, ".vault.proRata"),
                a.safe
            )
        );
    }

    function _settlerInit(string memory p, Addresses memory a) internal pure returns (bytes memory) {
        MigrationSettler.Config memory c = MigrationSettler.Config({
            poolManager: vm.parseJsonAddress(p, ".poolManager"),
            positionManager: vm.parseJsonAddress(p, ".positionManager"),
            permit2: vm.parseJsonAddress(p, ".permit2"),
            safe: a.safe,
            v1: vm.parseJsonAddress(p, ".v1"),
            weth: vm.parseJsonAddress(p, ".weth"),
            v2: a.token,
            v3Tail: vm.parseJsonAddress(p, ".v3Tail"),
            oldPoolId: vm.parseJsonBytes32(p, ".oldPool.poolId"),
            // forge-lint: disable-next-line(unsafe-typecast)
            lpFee: uint24(vm.parseJsonUint(p, ".successorPool.lpFee")),
            // forge-lint: disable-next-line(unsafe-typecast)
            tickSpacing: int24(vm.parseJsonInt(p, ".successorPool.tickSpacing")),
            // The same address the hook is deployed with as its treasury: the settler refuses any other.
            feeRecipient: vm.parseJsonAddress(p, ".hook.feeRecipient")
        });
        return abi.encodePacked(type(MigrationSettler).creationCode, abi.encode(c));
    }

    /// @dev The hook's creation code comes from contracts/fee-hook's build (resolved.json carries it); its
    ///      constructor is (poolManager, treasury, initializer, currency0, currency1, lpFee, tickSpacing).
    ///      The salt is the smallest one whose CREATE2 address has exactly the launch flags in its low 14 bits.
    function _hook(string memory p, Addresses memory a, address deployer)
        internal
        pure
        returns (bytes memory init, bytes32 salt)
    {
        init = abi.encodePacked(vm.parseJsonBytes(p, ".hook.creationCode"), _hookArgs(p, a));
        bytes32 initHash = keccak256(init);
        for (uint256 i; i < MAX_HOOK_SALTS; ++i) {
            address candidate = _create2Hashed(deployer, bytes32(i), initHash);
            if ((uint160(candidate) & ALL_HOOK_MASK) == HOOK_FLAGS) return (init, bytes32(i));
        }
        revert("DeployPlan: no hook salt below MAX_HOOK_SALTS");
    }

    /// @dev (poolManager, treasury, initializer = the settler, currency0, currency1, lpFee, tickSpacing).
    function _hookArgs(string memory p, Addresses memory a) internal pure returns (bytes memory) {
        address weth = vm.parseJsonAddress(p, ".weth");
        (address c0, address c1) = a.token < weth ? (a.token, weth) : (weth, a.token);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint24 lpFee = uint24(vm.parseJsonUint(p, ".successorPool.lpFee"));
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 spacing = int24(vm.parseJsonInt(p, ".successorPool.tickSpacing"));
        return abi.encode(
            vm.parseJsonAddress(p, ".poolManager"),
            vm.parseJsonAddress(p, ".hook.feeRecipient"),
            a.settler,
            c0,
            c1,
            lpFee,
            spacing
        );
    }

    function _create2(address deployer, bytes32 salt, bytes memory init) internal pure returns (address) {
        return _create2Hashed(deployer, salt, keccak256(init));
    }

    function _create2Hashed(address deployer, bytes32 salt, bytes32 initHash) internal pure returns (address) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
    }

    function _tail(bytes memory data, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(data.length - from);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[from + i];
        }
    }
}
