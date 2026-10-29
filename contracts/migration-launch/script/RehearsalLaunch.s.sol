// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationVault} from "@surplus/migration/src/MigrationVault.sol";
import {MigrationSettler} from "../src/MigrationSettler.sol";
import {PoolKey} from "../src/LaunchInterfaces.sol";
import {LadderMirror} from "../test/utils/LadderMirror.sol";

interface ILaunchVm {
    function readFile(string calldata path) external view returns (string memory);
    function envString(string calldata name) external view returns (string memory);
    function parseJsonAddress(string calldata json, string calldata key) external pure returns (address);
    function parseJsonString(string calldata json, string calldata key) external pure returns (string memory);
    function parseJsonStringArray(string calldata json, string calldata key) external pure returns (string[] memory);
    function parseBytes32(string calldata value) external pure returns (bytes32);
    function parseUint(string calldata value) external pure returns (uint256);
    function addr(uint256 privateKey) external pure returns (address);
    function sign(uint256 privateKey, bytes32 digest) external pure returns (uint8 v, bytes32 r, bytes32 s);
    function startBroadcast(address signer) external;
    function stopBroadcast() external;
    function load(address target, bytes32 slot) external view returns (bytes32);
}

interface ILaunchSafe {
    function nonce() external view returns (uint256);
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce_
    ) external view returns (bytes32);
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool);
}

interface ILaunchToken {
    function cap() external view returns (uint256);
}

/**
 * @notice REHEARSAL ONLY, for a private anvil. It executes commitRoot and the atomic launch batch through the
 *         real Safe with the public rehearsal keys, so that later phases (the push plan) run against a vault
 *         whose root is committed and whose claims are live, as on launch day. The launch batch uses the
 *         kit's simulate-then-sign rule. Run it twice: first SIMULATE=1 with no broadcast, which reads the
 *         unconstrained result; then with the printed limits (MIN_WETH_OUT, V2_BUDGET) and --broadcast.
 * @dev    Env: SURPLUS_TREE (the snapshot's tree.json), SIMULATE (1 or 0), MIN_WETH_OUT, V2_BUDGET, EXECUTOR
 *         (the account that sends execTransaction; any account can, the Safe checks the signatures).
 */
contract RehearsalLaunch {
    ILaunchVm internal constant vm = ILaunchVm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    address internal constant V1 = 0xC52aeDec3374422d7510E294cfAa90799595CBa3;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant MULTISEND_CALL_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address internal constant OLD_HOOK = 0xbB7784A4d481184283Ed89619A3e3ed143e1Adc0;
    bytes32 internal constant OLD_POOL_ID = 0xfc25fdd217e288d03a877f0b7d49e0bbe52b2288c88de929125062569fc7eb2a;
    uint160 internal constant MAX_SQRT_MINUS_1 = 1461446703485210103287273052203988822378723970341;

    function run() external returns (uint256 wethRaised, uint256 v2Seeded) {
        string memory d = vm.readFile("kit/output/deploy/deployment.json");
        ILaunchSafe safe = ILaunchSafe(vm.parseJsonAddress(d, ".safe"));
        MigrationVault vault = MigrationVault(vm.parseJsonAddress(d, ".vault"));
        MigrationSettler settler = MigrationSettler(vm.parseJsonAddress(d, ".settler"));
        address v2 = vm.parseJsonAddress(d, ".v2");
        address hook = vm.parseJsonAddress(d, ".hook");
        bool simulate = keccak256(bytes(vm.envString("SIMULATE"))) == keccak256("1");
        address executor = vm.parseJsonAddress(vm.readFile("kit/params.rehearsal.json"), ".operators.deployer");

        string memory tree = vm.readFile(vm.envString("SURPLUS_TREE"));
        bytes32 root = vm.parseBytes32(vm.parseJsonString(tree, ".root"));
        uint256 total = vm.parseUint(vm.parseJsonString(tree, ".total"));

        vm.startBroadcast(executor);
        if (vault.root() == bytes32(0)) {
            _exec(safe, address(vault), abi.encodeCall(MigrationVault.commitRoot, (root, total)), 0);
        }
        require(vault.root() == root && vault.totalClaimable() == total, "commitRoot");

        MigrationSettler.Params memory p = _params(vault, v2, hook);
        uint256 budget;
        if (simulate) {
            budget = ILaunchToken(v2).cap() - total;
        } else {
            p.minWethOut = vm.parseUint(vm.envString("MIN_WETH_OUT"));
            budget = vm.parseUint(vm.envString("V2_BUDGET"));
        }
        _exec(safe, MULTISEND_CALL_ONLY, _batch(vault, settler, v2, p, total, budget), 1);
        vm.stopBroadcast();
        require(vault.claimsActive(), "claims not active");
        wethRaised = settler.wethRaised();
        v2Seeded = settler.v2Seeded();
    }

    function _params(MigrationVault vault, address v2, address hook)
        internal
        view
        returns (MigrationSettler.Params memory p)
    {
        bool v2First = v2 < WETH;
        p.oldKey = PoolKey(WETH, V1, 0x800000, 200, OLD_HOOK);
        p.v1In = vault.totalDepositedV1() - vault.totalLedgerWithdrawnV1();
        p.tailIn = p.v1In / 10;
        p.tailLimit = MAX_SQRT_MINUS_1;
        p.newKey = PoolKey(v2First ? v2 : WETH, v2First ? WETH : v2, 3000, 60, hook);
        // The kit's rule: open at the old pool's tick rounded to the grid; the v2 side copies its v1 ladder.
        (, int24 oldTick) = LadderMirror.slot0(POOL_MANAGER, OLD_POOL_ID);
        int24 seamOld = LadderMirror.toGrid(oldTick, 60);
        p.openTick = v2First ? -seamOld : seamOld;
        (p.v2Ranges,) = LadderMirror.mirror(POOL_MANAGER, OLD_POOL_ID, 200, 60, seamOld, v2First, 100);
    }

    function _batch(
        MigrationVault vault,
        MigrationSettler settler,
        address v2,
        MigrationSettler.Params memory p,
        uint256 backing,
        uint256 budget
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "multiSend(bytes)",
            abi.encodePacked(
                _packed(v2, abi.encodeWithSignature("mint(address,uint256)", address(vault), backing)),
                _packed(address(vault), abi.encodeCall(MigrationVault.activateClaims, ())),
                _packed(
                    address(vault), abi.encodeCall(MigrationVault.withdrawV1ForSettlement, (address(settler), p.v1In))
                ),
                _packed(v2, abi.encodeWithSignature("mint(address,uint256)", address(settler), budget)),
                _packed(address(settler), abi.encodeCall(MigrationSettler.settle, (p)))
            )
        );
    }

    function _packed(address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), to, uint256(0), uint256(data.length), data);
    }

    /// @dev Two of the three rehearsal owners sign, in ascending address order.
    function _exec(ILaunchSafe safe, address to, bytes memory data, uint8 operation) internal {
        bytes32 hash = safe.getTransactionHash(to, 0, data, operation, 0, 0, 0, address(0), address(0), safe.nonce());
        bool ok =
            safe.execTransaction(to, 0, data, operation, 0, 0, 0, address(0), payable(address(0)), _signatures(hash));
        require(ok, "execTransaction");
    }

    function _signatures(bytes32 hash) internal view returns (bytes memory) {
        string[] memory keys =
            vm.parseJsonStringArray(vm.readFile("kit/params.rehearsal.json"), ".rehearsalKeys.owners");
        uint256 a = vm.parseUint(keys[0]);
        uint256 b = vm.parseUint(keys[1]);
        if (vm.addr(b) < vm.addr(a)) (a, b) = (b, a);
        (uint8 va, bytes32 ra, bytes32 sa) = vm.sign(a, hash);
        (uint8 vb, bytes32 rb, bytes32 sb) = vm.sign(b, hash);
        return abi.encodePacked(ra, sa, va, rb, sb, vb);
    }
}
