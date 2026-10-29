// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDeployVm} from "./DeployPlan.s.sol";
import {IDeployed} from "./DeployDryRun.s.sol";
import {SurplusTokenV2BaseSepolia} from "@surplus/token-v2/src/SurplusTokenV2BaseSepolia.sol";
import {MigrationVault} from "@surplus/migration/src/MigrationVault.sol";

interface ISepoliaVm is IDeployVm {
    function prank(address sender) external;
    function load(address target, bytes32 slot) external view returns (bytes32);
}

/// @notice In-memory execution only: no broadcast cheatcode, keys or production kit output.
contract SepoliaDryRun {
    ISepoliaVm private constant vm = ISepoliaVm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        require(block.chainid == 84532, "Sepolia only");
        string memory path = vm.envString("TESTNET_PLAN");
        string memory p = vm.readFile(path);
        require(block.number == vm.parseJsonUint(p, ".preflight.block.number"), "wrong fork block");
        string[4] memory dependencies = ["singleton", "proxyFactory", "multiSendCallOnly", "create2Deployer"];
        for (uint256 i; i < dependencies.length; ++i) {
            string memory key = string.concat(".preflight.dependencies.contracts.", dependencies[i]);
            address target = vm.parseJsonAddress(p, string.concat(key, ".address"));
            require(
                target.codehash == vm.parseJsonBytes32(p, string.concat(key, ".runtimeCodeHash")), "dependency hash"
            );
        }
        string[5] memory names = ["safe", "v1", "implementation", "token", "vault"];
        string[5] memory indexes = ["0", "1", "2", "3", "4"];
        for (uint256 i; i < names.length; ++i) {
            address expected = vm.parseJsonAddress(p, string.concat(".addresses.", names[i]));
            require(expected.code.length == 0, "occupied deployment address");
            string memory key = string.concat(".transactions[", indexes[i], "]");
            address target = vm.parseJsonAddress(p, string.concat(key, ".to"));
            bytes memory data = vm.parseJsonBytes(p, string.concat(key, ".data"));
            vm.prank(vm.parseJsonAddress(p, ".params.deployer"));
            (bool ok, bytes memory result) = target.call(data);
            require(ok, string(result));
            require(expected.code.length != 0, "wrong deployment address");
        }
        _check(p);
        string memory out;
        vm.serializeString("simulation", "planHash", vm.parseJsonString(p, ".planHash"));
        for (uint256 i; i < names.length; ++i) {
            address expected = vm.parseJsonAddress(p, string.concat(".addresses.", names[i]));
            out = vm.serializeBytes("simulation", names[i], expected.code);
        }
        vm.writeFile(string.concat(path, ".simulation.json"), out);
    }

    function _check(string memory p) private view {
        address governance = vm.parseJsonAddress(p, ".addresses.safe");
        IDeployed s = IDeployed(governance);
        address[] memory expected = vm.parseJsonAddressArray(p, ".params.governance.owners");
        address[] memory got = s.getOwners();
        require(keccak256(abi.encode(got)) == keccak256(abi.encode(expected)), "Safe owners/order");
        require(
            s.getThreshold() == vm.parseJsonUint(p, ".params.governance.threshold") && s.nonce() == 0, "Safe quorum"
        );
        require(
            vm.load(governance, bytes32(0))
                == bytes32(
                    uint256(uint160(vm.parseJsonAddress(p, ".preflight.dependencies.contracts.singleton.address")))
                ),
            "Safe singleton"
        );
        SurplusTokenV2BaseSepolia t = SurplusTokenV2BaseSepolia(vm.parseJsonAddress(p, ".addresses.token"));
        require(t.CANONICAL_CHAIN_ID() == 84532 && t.decimals() == 18 && t.totalSupply() == 0, "token identity/supply");
        require(
            keccak256(bytes(t.name())) == keccak256(bytes(vm.parseJsonString(p, ".params.token.name"))), "token name"
        );
        require(
            keccak256(bytes(t.symbol())) == keccak256(bytes(vm.parseJsonString(p, ".params.token.symbol"))),
            "token symbol"
        );
        require(t.cap() == vm.parseJsonUint(p, ".params.token.capWei"), "token cap");
        require(
            vm.load(address(t), IMPLEMENTATION_SLOT)
                == bytes32(uint256(uint160(vm.parseJsonAddress(p, ".addresses.implementation")))),
            "implementation slot"
        );
        bytes32[4] memory roles = [bytes32(0), t.MINTER_ROLE(), t.BURNER_ROLE(), t.UPGRADER_ROLE()];
        for (uint256 i; i < roles.length; ++i) {
            require(t.hasRole(roles[i], governance), "Safe missing role");
            require(!t.hasRole(roles[i], vm.parseJsonAddress(p, ".params.deployer")), "EOA retains role");
        }
        MigrationVault v = MigrationVault(vm.parseJsonAddress(p, ".addresses.vault"));
        require(v.owner() == governance && v.pendingOwner() == address(0), "vault owner");
        require(
            address(v.V1()) == vm.parseJsonAddress(p, ".addresses.v1") && address(v.V2()) == address(t), "vault tokens"
        );
        require(v.DEPOSIT_DEADLINE() == vm.parseJsonUint(p, ".params.vault.depositDeadline"), "deposit deadline");
        require(v.COMMIT_DEADLINE() == vm.parseJsonUint(p, ".params.vault.commitDeadline"), "commit deadline");
        require(v.EXECUTION_WINDOW() == vm.parseJsonUint(p, ".params.vault.executionWindowSeconds"), "execution window");
        require(v.CLAIM_PERIOD() == 0 && v.MIGRATION_RATE_BPS() == 10000 && v.PRO_RATA_ENABLED(), "vault deal");
        require(v.phase() == MigrationVault.Phase.Open && !v.claimsEverActive(), "fresh vault");
    }
}
