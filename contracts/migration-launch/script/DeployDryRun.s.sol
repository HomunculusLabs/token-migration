// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IDryRunVm {
    function readFile(string calldata path) external view returns (string memory);
    function parseJsonAddress(string calldata json, string calldata key) external pure returns (address);
    function parseJsonAddressArray(string calldata json, string calldata key) external pure returns (address[] memory);
    function parseJsonUint(string calldata json, string calldata key) external pure returns (uint256);
    function parseJsonInt(string calldata json, string calldata key) external pure returns (int256);
    function parseJsonString(string calldata json, string calldata key) external pure returns (string memory);
    function parseJsonBytes32(string calldata json, string calldata key) external pure returns (bytes32);
    function parseJsonBytes(string calldata json, string calldata key) external pure returns (bytes memory);
    function parseJsonBool(string calldata json, string calldata key) external pure returns (bool);
    function load(address target, bytes32 slot) external view returns (bytes32);
    function prank(address sender) external;
}

interface IDeployed {
    // Safe 1.4.1
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
    // SurplusTokenV2
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function cap() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getRoleMemberCount(bytes32 role) external view returns (uint256);
    // MigrationVault
    function V1() external view returns (address);
    function V2() external view returns (address);
    function DEPOSIT_DEADLINE() external view returns (uint256);
    function COMMIT_DEADLINE() external view returns (uint256);
    function MIGRATION_RATE_BPS() external view returns (uint256);
    function PRO_RATA_ENABLED() external view returns (bool);
    function owner() external view returns (address);
    function phase() external view returns (uint8);
    // MigrationSettler
    function SAFE() external view returns (address);
    function OLD_POOL_ID() external view returns (bytes32);
    function LP_FEE() external view returns (uint24);
    function TICK_SPACING() external view returns (int24);
    function WETH() external view returns (address);
    function FEE_RECIPIENT() external view returns (address);
    // hook
    function INITIALIZER() external view returns (address);
    function POOL_MANAGER() external view returns (address);
    function TREASURY() external view returns (address);
    function FEE_PIPS() external view returns (uint24);
}

/**
 * @title DeployDryRun
 * @notice Launch kit phase "deploy-plan", step 2: replays every deployment in kit/output/deploy/plan.json on a
 *         fork, in order, from the planned deployer, and checks each lands at its predicted address with the
 *         decided settings: the Safe's owners and threshold; the token's metadata, cap, zero supply and roles
 *         (all held by the Safe, none by the deployer); the vault's deal; the settler's pins; the hook's flags
 *         and initializer. Run it WITHOUT --broadcast: forge then executes it in memory only.
 * @dev    A step whose address already has code is checked but not redeployed, so the same run confirms a
 *         partly finished launch-day deployment.
 */
contract DeployDryRun {
    IDryRunVm internal constant vm = IDryRunVm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    function run() external {
        string memory r = vm.readFile("kit/output/deploy/resolved.json");
        string memory p = vm.readFile("kit/output/deploy/plan.json");
        address deployer = vm.parseJsonAddress(r, ".operators.deployer");
        address create2 = vm.parseJsonAddress(r, ".create2Deployer");

        address safe = vm.parseJsonAddress(p, ".safe");
        if (safe.code.length == 0) {
            bytes memory data = abi.encodeWithSignature(
                "createProxyWithNonce(address,bytes,uint256)",
                vm.parseJsonAddress(r, ".safe141.singleton"),
                vm.parseJsonBytes(p, ".safeInitializer"),
                vm.parseJsonUint(r, ".governance.saltNonce")
            );
            _send(deployer, vm.parseJsonAddress(r, ".safe141.proxyFactory"), data);
        }
        _deploy(deployer, create2, p, "tokenImplementation", ".salts.tokenImplementation", r);
        _deploy(deployer, create2, p, "token", ".salts.tokenProxy", r);
        _deploy(deployer, create2, p, "vault", ".salts.vault", r);
        _deploy(deployer, create2, p, "settler", ".salts.settler", r);
        _deployHook(deployer, create2, p);

        _checkSafe(r, safe);
        _checkToken(r, p, safe, deployer);
        _checkVault(r, p, safe);
        _checkSettler(r, p, safe);
        _checkHook(r, p);
    }

    function _deploy(
        address deployer,
        address create2,
        string memory p,
        string memory key,
        string memory saltKey,
        string memory r
    ) internal {
        address expected = vm.parseJsonAddress(p, string.concat(".", key));
        if (expected.code.length == 0) {
            bytes memory init = vm.parseJsonBytes(p, string.concat(".", _initKey(key)));
            _send(deployer, create2, abi.encodePacked(vm.parseJsonBytes32(r, saltKey), init));
        }
        require(expected.code.length != 0, string.concat(key, ": nothing deployed at the predicted address"));
    }

    function _deployHook(address deployer, address create2, string memory p) internal {
        address expected = vm.parseJsonAddress(p, ".hook");
        if (expected.code.length == 0) {
            _send(
                deployer,
                create2,
                abi.encodePacked(vm.parseJsonBytes32(p, ".hookSalt"), vm.parseJsonBytes(p, ".hookInitCode"))
            );
        }
        require(expected.code.length != 0, "hook: nothing deployed at the predicted address");
    }

    function _initKey(string memory key) internal pure returns (string memory) {
        if (keccak256(bytes(key)) == keccak256("tokenImplementation")) return "tokenImplementationInitCode";
        if (keccak256(bytes(key)) == keccak256("token")) return "tokenProxyInitCode";
        return string.concat(key, "InitCode");
    }

    function _send(address from, address to, bytes memory data) internal {
        vm.prank(from);
        (bool ok, bytes memory ret) = to.call(data);
        require(ok, string(ret));
    }

    function _checkSafe(string memory r, address safe) internal view {
        IDeployed s = IDeployed(safe);
        address[] memory want = vm.parseJsonAddressArray(r, ".governance.owners");
        address[] memory got = s.getOwners();
        require(got.length == want.length, "Safe: owner count");
        for (uint256 i; i < want.length; ++i) {
            bool found;
            for (uint256 j; j < got.length; ++j) {
                if (got[j] == want[i]) found = true;
            }
            require(found, "Safe: owner missing");
        }
        require(s.getThreshold() == vm.parseJsonUint(r, ".governance.threshold"), "Safe: threshold");
        require(
            address(uint160(uint256(vm.load(safe, bytes32(0))))) == vm.parseJsonAddress(r, ".safe141.singleton"),
            "Safe: singleton"
        );
    }

    function _checkToken(string memory r, string memory p, address safe, address deployer) internal view {
        IDeployed t = IDeployed(vm.parseJsonAddress(p, ".token"));
        require(
            keccak256(bytes(t.name())) == keccak256(bytes(vm.parseJsonString(r, ".token.name")))
                && keccak256(bytes(t.symbol())) == keccak256(bytes(vm.parseJsonString(r, ".token.symbol"))),
            "token: metadata"
        );
        require(t.cap() == vm.parseJsonUint(r, ".token.capWei") && t.totalSupply() == 0, "token: cap/supply");
        require(
            address(uint160(uint256(vm.load(address(t), IMPLEMENTATION_SLOT))))
                == vm.parseJsonAddress(p, ".tokenImplementation"),
            "token: implementation"
        );
        bytes32[4] memory roles = [bytes32(0), MINTER_ROLE, BURNER_ROLE, UPGRADER_ROLE];
        for (uint256 i; i < roles.length; ++i) {
            require(t.hasRole(roles[i], safe), "token: the Safe lacks a role");
            require(!t.hasRole(roles[i], deployer), "token: the deployer holds a role");
        }
    }

    function _checkVault(string memory r, string memory p, address safe) internal view {
        IDeployed v = IDeployed(vm.parseJsonAddress(p, ".vault"));
        require(v.V1() == vm.parseJsonAddress(r, ".v1") && v.V2() == vm.parseJsonAddress(p, ".token"), "vault: tokens");
        require(
            v.DEPOSIT_DEADLINE() == vm.parseJsonUint(r, ".vault.depositDeadline")
                && v.COMMIT_DEADLINE() == vm.parseJsonUint(r, ".vault.commitDeadline"),
            "vault: deadlines"
        );
        require(
            v.MIGRATION_RATE_BPS() == vm.parseJsonUint(r, ".vault.rateBps")
                && v.PRO_RATA_ENABLED() == vm.parseJsonBool(r, ".vault.proRata"),
            "vault: rate/proRata"
        );
        require(v.owner() == safe && v.phase() == 0, "vault: owner/phase");
    }

    function _checkSettler(string memory r, string memory p, address safe) internal view {
        IDeployed s = IDeployed(vm.parseJsonAddress(p, ".settler"));
        require(s.SAFE() == safe && s.V2() == vm.parseJsonAddress(p, ".token"), "settler: Safe/v2");
        require(s.OLD_POOL_ID() == vm.parseJsonBytes32(r, ".oldPool.poolId"), "settler: old pool");
        require(
            uint256(s.LP_FEE()) == vm.parseJsonUint(r, ".successorPool.lpFee")
                && int256(s.TICK_SPACING()) == vm.parseJsonInt(r, ".successorPool.tickSpacing"),
            "settler: successor fee/spacing"
        );
        require(s.WETH() == vm.parseJsonAddress(r, ".weth"), "settler: WETH");
        require(s.FEE_RECIPIENT() == vm.parseJsonAddress(r, ".hook.feeRecipient"), "settler: fee recipient");
    }

    function _checkHook(string memory r, string memory p) internal view {
        address hook = vm.parseJsonAddress(p, ".hook");
        require((uint160(hook) & ((1 << 14) - 1)) == 0x2044, "hook: flags are not exactly 0x2044");
        require(IDeployed(hook).INITIALIZER() == vm.parseJsonAddress(p, ".settler"), "hook: initializer");
        require(IDeployed(hook).POOL_MANAGER() == vm.parseJsonAddress(r, ".poolManager"), "hook: pool manager");
        // The settler refuses a successor hook whose fee or treasury differs; catch it here, before anyone signs.
        // Static calls, so a hook without these getters (not the fee hook) fails with a reason, not empty data.
        (bool ok, bytes memory ret) = hook.staticcall(abi.encodeCall(IDeployed.TREASURY, ()));
        require(
            ok && ret.length == 32 && abi.decode(ret, (address)) == vm.parseJsonAddress(r, ".hook.feeRecipient"),
            "hook: fees do not go to the decided recipient"
        );
        (ok, ret) = hook.staticcall(abi.encodeCall(IDeployed.FEE_PIPS, ()));
        require(ok && ret.length == 32 && abi.decode(ret, (uint256)) == 15_000, "hook: fee is not 1.5%");
    }
}
