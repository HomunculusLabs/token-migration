// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MigrationVault} from "@surplus/migration/src/MigrationVault.sol";
import {SurplusFeeHook} from "@surplus/fee-hook/src/SurplusFeeHook.sol";
import {MigrationSettler} from "../../../src/MigrationSettler.sol";
import {IPoolManager, IPositionManager, IUnlockCallback, PoolKey, SwapParams} from "../../../src/LaunchInterfaces.sol";
import {LaunchMath} from "../../../src/LaunchMath.sol";
import {Test} from "../../Base.t.sol";
import {LadderMirror} from "../../utils/LadderMirror.sol";

interface RVm {
    function readFile(string calldata path) external view returns (string memory);
    function writeFile(string calldata path, string calldata data) external;
    function isFile(string calldata path) external view returns (bool);
    function envOr(string calldata name, string calldata defaultValue) external view returns (string memory);
    function parseJsonAddress(string calldata json, string calldata key) external pure returns (address);
    function parseJsonAddressArray(string calldata json, string calldata key) external pure returns (address[] memory);
    function parseJsonUintArray(string calldata json, string calldata key) external pure returns (uint256[] memory);
    function parseJsonUint(string calldata json, string calldata key) external pure returns (uint256);
    function parseJsonString(string calldata json, string calldata key) external pure returns (string memory);
    function parseJsonStringArray(string calldata json, string calldata key) external pure returns (string[] memory);
    function parseJsonTypeArray(string calldata json, string calldata key, string calldata typeDescription)
        external
        pure
        returns (bytes memory);
    function parseUint(string calldata value) external pure returns (uint256);
    function parseBytes32(string calldata value) external pure returns (bytes32);
    function serializeUint(string calldata objectKey, string calldata valueKey, uint256 value)
        external
        returns (string memory);
    function serializeAddress(string calldata objectKey, string calldata valueKey, address value)
        external
        returns (string memory);
    function serializeBytes32(string calldata objectKey, string calldata valueKey, bytes32 value)
        external
        returns (string memory);
    function cool(address target) external;
    function skip(bool skipTest, string calldata reason) external;
}

interface IFullSafe {
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

interface IMulticall3 {
    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    struct Result {
        bool success;
        bytes returnData;
    }

    function aggregate3(Call3[] calldata calls) external payable returns (Result[] memory returnData);
}

interface IGasPriceOracle {
    function getL1FeeUpperBound(uint256 unsignedTxSize) external view returns (uint256);
}

interface IExtsloadFull {
    function extsload(bytes32 slot) external view returns (bytes32);
}

/**
 * @title FullScaleLaunchRehearsal
 * @notice Spec §5 at full scale, from the state the launch kit leaves: the planned system deployed at its
 *         predicted addresses (`kit/launch.py deploy-plan`, rehearsal driver `kit/rehearse.py deploy`), every
 *         eligible holder at the pin deposited its full balance (`rehearse.py deposit`), the deposit window
 *         closed, and the tree built and 3-way verified by `kit/launch.py snapshot`. From there it runs the
 *         Safe's `commitRoot`, the one atomic launch batch, the push to every holder, live trades through the
 *         real hook and the Safe's fee withdrawal. Each failure path starts from the same pre-commit state.
 * @dev    Runs only against a fork that holds that state; everywhere else it skips. Inputs: SURPLUS_TREE (the
 *         snapshot's tree.json), kit/output/deploy/{deployment,resolved}.json, kit/output/cohort/cohort.json,
 *         kit/params.rehearsal.json. Signs with the public throwaway rehearsal keys through the real Safe 1.4.1.
 */
contract FullScaleLaunchRehearsal is Test, IUnlockCallback {
    RVm internal constant rvm = RVm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address internal constant V1 = 0xC52aeDec3374422d7510E294cfAa90799595CBa3;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant MULTISEND_CALL_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;
    address internal constant GAS_PRICE_ORACLE = 0x420000000000000000000000000000000000000F;
    address internal constant V3_TAIL = 0xbCf23F30a90f6D7c288fACdc932fF8F8B68b0f30;
    address internal constant OLD_HOOK = 0xbB7784A4d481184283Ed89619A3e3ed143e1Adc0;
    bytes32 internal constant OLD_POOL_ID = 0xfc25fdd217e288d03a877f0b7d49e0bbe52b2288c88de929125062569fc7eb2a;
    uint160 internal constant V3_MAX_SQRT_MINUS_1 = 1461446703485210103287273052203988822378723970341;
    uint160 internal constant MIN_SQRT_PRICE_PLUS_1 = 4_295_128_740;
    uint256 internal constant GAS_CAP = 1 << 24;
    uint256 internal constant CALLDATA_CAP = 128 * 1024;
    uint256 internal constant CLAIMS_PER_BATCH = 120;
    /// @dev The fullscale-260929 cohort: every eligible holder at the pin.
    uint256 internal constant FULL_SCALE_HOLDERS = 6338;
    /// @dev 250 refunds measured 15.4M gas (92% of the cap); 200 leaves margin.
    uint256 internal constant REFUNDS_PER_BATCH = 200;
    string internal constant LEAF_TYPE = "Leaf(uint256 index,address account,uint256 amount,bytes32[] proof)";
    string internal constant DEPLOYMENT = "kit/output/deploy/deployment.json";

    struct Leaf {
        uint256 index;
        address account;
        uint256 amount;
        bytes32[] proof;
    }

    struct PushStats {
        uint256 batches;
        uint256 calls;
        uint256 failures;
        uint256 execGas;
        uint256 totalTxGas;
        uint256 maxTxGas;
        uint256 totalBytes;
        uint256 maxBytes;
        uint256 l1FeeUpperWei;
    }

    struct Launch {
        MigrationSettler.Params p;
        uint256 backing;
        uint256 budget;
        uint256 simRaised;
        uint256 simV2;
        uint256 batchGas;
        uint256 tailWeth;
        uint160 oldSqrtBefore;
        uint160 oldSqrtAfter;
    }

    IFullSafe internal safe;
    SurplusTokenV2Like internal v2;
    MigrationVault internal vault;
    MigrationSettler internal settler;
    SurplusFeeHook internal hook;
    address internal relayer;
    uint256[] internal ownerKeys;
    address[] internal holders;
    uint256[] internal amounts;
    uint256 internal cohortTotal;
    uint256 internal v1SupplyBefore;

    function setUp() public {
        if (block.chainid != 8453 || !rvm.isFile(DEPLOYMENT)) {
            rvm.skip(true, "no rehearsal deployment");
            return;
        }
        string memory d = rvm.readFile(DEPLOYMENT);
        vault = MigrationVault(rvm.parseJsonAddress(d, ".vault"));
        if (address(vault).code.length == 0 || block.timestamp <= vault.DEPOSIT_DEADLINE()) {
            rvm.skip(true, "this fork does not hold the closed rehearsal deposit window");
            return;
        }
        safe = IFullSafe(rvm.parseJsonAddress(d, ".safe"));
        v2 = SurplusTokenV2Like(rvm.parseJsonAddress(d, ".v2"));
        settler = MigrationSettler(rvm.parseJsonAddress(d, ".settler"));
        hook = SurplusFeeHook(rvm.parseJsonAddress(d, ".hook"));
        string memory r = rvm.readFile("kit/params.rehearsal.json");
        relayer = rvm.parseJsonAddress(r, ".operators.relayer");
        string[] memory keys = rvm.parseJsonStringArray(r, ".rehearsalKeys.owners");
        for (uint256 i; i < keys.length; ++i) {
            ownerKeys.push(rvm.parseUint(keys[i]));
        }
        _loadCohort();
        v1SupplyBefore = IERC20(V1).totalSupply();
        require(vault.phase() == MigrationVault.Phase.Open && vault.root() == bytes32(0), "not the pre-commit state");
        require(
            vault.totalDepositedV1() == cohortTotal && IERC20(V1).balanceOf(address(vault)) == cohortTotal,
            "vault custody != the cohort"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // The launch, end to end
    // ---------------------------------------------------------------------------------------------

    function test_00_TreeIsTheCohortAtOneToOne() public {
        (bytes32 root, uint256 total, Leaf[] memory leaves) = _tree();
        string memory e = rvm.readFile("kit/output/cohort/expected-root.json");
        assertEq(root, rvm.parseBytes32(rvm.parseJsonString(e, ".root")), "root != the cohort's expected root");
        assertEq(leaves.length, holders.length, "one leaf per holder");
        assertEq(total, cohortTotal, "total == every eligible v1 at the pin (1:1)");
        for (uint256 i; i < leaves.length; ++i) {
            require(leaves[i].account == holders[i] && leaves[i].amount == amounts[i], "leaf != cohort entry");
        }
        emit log_named_uint("holders", leaves.length);
        emit log_named_uint("v1_deposited_wei", cohortTotal);
    }

    function test_01_FullLifecycle() public {
        (bytes32 root, uint256 total, Leaf[] memory leaves) = _tree();
        _commitRoot(root, total, true);
        Launch memory l = _launch();
        uint256 v2SupplyAfterLaunch = v2.totalSupply();

        bytes[] memory expectFail = _selfClaims(leaves);
        PushStats memory s = _push(leaves, expectFail);
        require(s.failures == 4 && s.calls == leaves.length, "push must skip exactly the 4 self-claimers");
        require(v2.balanceOf(relayer) == 0, "the relayer received v2");
        for (uint256 i; i < leaves.length; ++i) {
            require(v2.balanceOf(leaves[i].account) == leaves[i].amount, "a holder did not get exactly its v2");
        }
        require(v2.balanceOf(address(vault)) == 0 && vault.totalClaimedAmount() == total, "vault not fully paid out");
        PushStats memory again = _push(leaves, new bytes[](0));
        require(again.failures == leaves.length, "a rerun of the push paid someone twice");

        uint256[4] memory fees = _trades(l.p.newKey, leaves);
        _withdrawFees();
        _writeResult(l, s, total, v2SupplyAfterLaunch, fees);
    }

    // ---------------------------------------------------------------------------------------------
    // Failure paths at full scale
    // ---------------------------------------------------------------------------------------------

    function test_02_SafeNeverCommitsSoThePreCommitTimeoutRefundsEveryone() public {
        vm.warp(vault.COMMIT_DEADLINE() + 1);
        vm.prank(relayer);
        vault.expireCommit();
        PushStats memory s = _pushRefunds();
        _assertEveryoneRefunded();
        emit log_named_uint("refund_batches", s.batches);
        emit log_named_uint("refund_max_tx_gas", s.maxTxGas);
        emit log_named_uint("refund_max_tx_bytes", s.maxBytes);
    }

    function test_03_NobodyActivatesSoTheExecutionTimeoutRefundsEveryone() public {
        (bytes32 root, uint256 total,) = _tree();
        _commitRoot(root, total, false);
        vm.warp(vault.rootCommittedAt() + vault.EXECUTION_WINDOW() + 1);
        vm.prank(relayer);
        vault.expireExecution();
        _pushRefunds();
        _assertEveryoneRefunded();
    }

    function test_04_FrontRunPoolInitRevertsTheWholeBatch() public {
        (bytes32 root, uint256 total,) = _tree();
        _commitRoot(root, total, false);
        (MigrationSettler.Params memory p, uint256 backing, uint256 budget,,) = _simulateAndSign();
        // The hook admits only the settler, so the only possible front-runner is the settler itself; this
        // is the worst case (a pre-initialized pool at 1/31 of the price), not a reachable attack.
        vm.prank(address(settler));
        IPoolManager(POOL_MANAGER).initialize(p.newKey, LaunchMath.sqrtPriceAtTick(p.openTick) / 31);
        uint256 nonceBefore = safe.nonce();
        (bool ok, bytes memory ret) = _safeCall(MULTISEND_CALL_ONLY, _batch(p, backing, budget), 1, 2);
        require(!ok && keccak256(ret) == keccak256(abi.encodeWithSignature("Error(string)", "GS013")), "not GS013");
        require(
            !vault.claimsActive() && v2.totalSupply() == 0 && IERC20(V1).balanceOf(address(vault)) == cohortTotal
                && IERC20(V1).balanceOf(address(settler)) == 0 && safe.nonce() == nonceBefore,
            "a failed batch left state behind"
        );
    }

    function test_05_WithdrawalAfterTheDeadlineIsRejected() public {
        for (uint256 i; i < holders.length; i += 997) {
            vm.prank(holders[i]);
            vm.expectRevert(abi.encodeWithSelector(MigrationVault.LedgerWithdrawalsFrozen.selector));
            vault.withdrawV1(1);
        }
        require(vault.totalLedgerWithdrawnV1() == 0, "a withdrawal went through");
    }

    function test_06_PlainTransferToTheVaultIsRescued() public {
        // Every cohort holder deposited its whole balance, so the stray comes from an excluded holder.
        address sender = 0x12cf078D3D4808dBdc69701F30b0B409aFF89Ec1;
        uint256 senderBefore = IERC20(V1).balanceOf(sender);
        uint256 stray = senderBefore / 3;
        require(stray != 0, "the stray sender holds no v1");
        uint256 ledger = vault.totalDepositedV1() - vault.totalLedgerWithdrawnV1();
        // Nothing to rescue while the vault holds exactly the ledger.
        (bool ok,) = _safeCall(address(vault), abi.encodeCall(MigrationVault.rescueV1, (relayer)), 0, 2);
        require(!ok, "rescued v1 the ledger owns");
        vm.prank(sender);
        require(IERC20(V1).transfer(address(vault), stray), "plain transfer");
        (ok,) = _safeCall(address(vault), abi.encodeCall(MigrationVault.rescueV1, (sender)), 0, 2);
        require(ok, "rescue");
        require(IERC20(V1).balanceOf(sender) == senderBefore, "the sender got exactly its stray back");
        require(IERC20(V1).balanceOf(address(vault)) == ledger, "the ledger's v1 stayed");
    }

    // ---------------------------------------------------------------------------------------------
    // Safe: commitRoot, the launch batch, fee withdrawal
    // ---------------------------------------------------------------------------------------------

    function _commitRoot(bytes32 root, uint256 total, bool proveThreshold) internal {
        bytes memory data = abi.encodeCall(MigrationVault.commitRoot, (root, total));
        if (proveThreshold) {
            uint256 nonceBefore = safe.nonce();
            (bool one, bytes memory ret) = _safeCall(address(vault), data, 0, 1);
            require(
                !one && keccak256(ret) == keccak256(abi.encodeWithSignature("Error(string)", "GS020")),
                "one signature must be refused (GS020)"
            );
            require(safe.nonce() == nonceBefore && vault.root() == bytes32(0), "a refused tx changed state");
        }
        (bool ok,) = _safeCall(address(vault), data, 0, 2);
        require(ok && vault.root() == root && vault.totalClaimable() == total, "commitRoot");
    }

    /// @dev What the signers do (kit safe-txs): simulate with no floor and the whole remaining cap, then derive
    ///      the signed limits. The simulation's state is discarded.
    function _simulateAndSign()
        internal
        returns (MigrationSettler.Params memory p, uint256 backing, uint256 budget, uint256 raised, uint256 used)
    {
        backing = vault.totalClaimable();
        p = _params(vault.totalDepositedV1() - vault.totalLedgerWithdrawnV1());
        uint256 snapshot = vm.snapshotState();
        (bool ok,) = _safeCall(MULTISEND_CALL_ONLY, _batch(p, backing, v2.cap() - backing), 1, 2);
        require(ok, "the unconstrained simulation must launch");
        raised = settler.wethRaised();
        used = settler.v2Seeded();
        require(vm.revertToState(snapshot), "discard the simulation");
        p.minWethOut = (raised * 995) / 1000;
        // The v2 side is fixed by the signed ranges, not by the sale: no drift margin.
        budget = used + 10;
    }

    function _launch() internal returns (Launch memory l) {
        (l.p, l.backing, l.budget, l.simRaised, l.simV2) = _simulateAndSign();
        l.oldSqrtBefore = _sqrtPrice(OLD_POOL_ID);
        uint256 tailBefore = IERC20(WETH).balanceOf(V3_TAIL);
        address[8] memory touched =
            [address(vault), address(v2), V1, WETH, POOL_MANAGER, POSITION_MANAGER, address(settler), V3_TAIL];
        for (uint256 i; i < touched.length; ++i) {
            rvm.cool(touched[i]);
        }
        bool ok;
        (ok,, l.batchGas) = _safeCallMeasured(MULTISEND_CALL_ONLY, _batch(l.p, l.backing, l.budget), 1, 2);
        require(ok, "the signed launch batch");
        require(l.batchGas < GAS_CAP, "launch batch above 2^24 gas");
        l.tailWeth = tailBefore - IERC20(WETH).balanceOf(V3_TAIL);
        l.oldSqrtAfter = _sqrtPrice(OLD_POOL_ID);

        require(settler.wethRaised() == l.simRaised && settler.wethRaised() >= l.p.minWethOut, "sale");
        (bool backed, uint256 v2Balance, uint256 claimable, uint256 custody, bool active,) = vault.verifySettlement();
        require(backed && active && v2Balance == l.backing && claimable == l.backing && custody == 0, "vault");
        require(settler.positionCount() == l.p.v2Ranges.length + 1, "one LP NFT per side position");
        for (uint256 i; i < settler.positionCount(); ++i) {
            uint256 id = settler.firstPositionId() + i;
            require(IPositionManager(POSITION_MANAGER).ownerOf(id) == address(safe), "LP NFT owner");
        }
        require(
            IERC20(V1).balanceOf(address(settler)) == 0 && IERC20(WETH).balanceOf(address(settler)) == 0
                && v2.balanceOf(address(settler)) == 0,
            "tokens left in the settler"
        );
        require(v2.totalSupply() == l.backing + l.budget, "v2 supply = backing + LP budget");
    }

    /// @dev The kit's rule: open at the old pool's tick rounded to the grid; the v2 side copies the old pool's v1
    ///      ladder above its price (adjacent segments within 1% merge).
    function _params(uint256 v1In) internal view returns (MigrationSettler.Params memory p) {
        bool v2First = address(v2) < WETH;
        p.oldKey = PoolKey(WETH, V1, 0x800000, 200, OLD_HOOK);
        p.v1In = v1In;
        p.tailIn = v1In / 10;
        p.tailLimit = V3_MAX_SQRT_MINUS_1;
        p.newKey = PoolKey(v2First ? address(v2) : WETH, v2First ? WETH : address(v2), 3000, 60, address(hook));
        (, int24 oldTick) = LadderMirror.slot0(POOL_MANAGER, OLD_POOL_ID);
        int24 seamOld = LadderMirror.toGrid(oldTick, 60);
        p.openTick = v2First ? -seamOld : seamOld;
        (p.v2Ranges,) = LadderMirror.mirror(POOL_MANAGER, OLD_POOL_ID, 200, 60, seamOld, v2First, 100);
    }

    function _batch(MigrationSettler.Params memory p, uint256 backing, uint256 budget)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSignature(
            "multiSend(bytes)",
            abi.encodePacked(
                _packed(address(v2), abi.encodeWithSignature("mint(address,uint256)", address(vault), backing)),
                _packed(address(vault), abi.encodeCall(MigrationVault.activateClaims, ())),
                _packed(
                    address(vault), abi.encodeCall(MigrationVault.withdrawV1ForSettlement, (address(settler), p.v1In))
                ),
                _packed(address(v2), abi.encodeWithSignature("mint(address,uint256)", address(settler), budget)),
                _packed(address(settler), abi.encodeCall(MigrationSettler.settle, (p)))
            )
        );
    }

    function _packed(address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), to, uint256(0), uint256(data.length), data);
    }

    function _withdrawFees() internal {
        address[2] memory currencies = [WETH, address(v2)];
        for (uint256 i; i < 2; ++i) {
            address c = currencies[i];
            uint256 team = hook.teamOwed(c) - hook.teamPaid(c);
            uint256 buyback = hook.buybackOwed(c) - hook.buybackPaid(c);
            uint256 before = IERC20(c).balanceOf(address(safe));
            (bool a,) =
                _safeCall(address(hook), abi.encodeCall(SurplusFeeHook.withdrawTeam, (c, address(safe), team)), 0, 2);
            (bool b,) = _safeCall(
                address(hook), abi.encodeCall(SurplusFeeHook.withdrawBuyback, (c, address(safe), buyback)), 0, 2
            );
            require(a && b, "fee withdrawal");
            require(IERC20(c).balanceOf(address(safe)) - before == team + buyback, "the Safe received both halves");
            require(IERC20(c).balanceOf(address(hook)) == 0, "fees left in the hook");
        }
    }

    function _safeCall(address to, bytes memory data, uint8 operation, uint256 signers)
        internal
        returns (bool ok, bytes memory ret)
    {
        (ok, ret,) = _safeCallMeasured(to, data, operation, signers);
    }

    /// @dev Signs with the first `signers` owners in ascending address order (Safe requires sorted signatures).
    ///      `gasUsed` covers only the call to the Safe (see _call).
    function _safeCallMeasured(address to, bytes memory data, uint8 operation, uint256 signers)
        internal
        returns (bool ok, bytes memory ret, uint256 gasUsed)
    {
        bytes32 hash = safe.getTransactionHash(to, 0, data, operation, 0, 0, 0, address(0), address(0), safe.nonce());
        uint256[] memory keys = _sortedKeys();
        bytes memory signatures;
        for (uint256 i; i < signers; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], hash);
            signatures = abi.encodePacked(signatures, r, s, v);
        }
        bytes memory callData = abi.encodeCall(
            IFullSafe.execTransaction, (to, 0, data, operation, 0, 0, 0, address(0), payable(address(0)), signatures)
        );
        (ok, ret, gasUsed) = _call(address(safe), callData);
        if (ok) ok = abi.decode(ret, (bool));
    }

    /// @dev A raw call whose gas reading excludes this test contract's own memory: with the whole tree loaded,
    ///      a Solidity `.call` would bill the return-data copy at this frame's (large) memory size. The callee
    ///      runs in a fresh frame, as it does under a real transaction.
    function _call(address target, bytes memory data) internal returns (bool ok, bytes memory ret, uint256 gasUsed) {
        uint256 g = gasleft();
        assembly ("memory-safe") {
            ok := call(gas(), target, 0, add(data, 0x20), mload(data), 0, 0)
        }
        gasUsed = g - gasleft();
        assembly ("memory-safe") {
            ret := mload(0x40)
            mstore(ret, returndatasize())
            returndatacopy(add(ret, 0x20), 0, returndatasize())
            mstore(0x40, add(add(ret, 0x20), and(add(returndatasize(), 31), not(31))))
        }
    }

    function _sortedKeys() internal view returns (uint256[] memory keys) {
        keys = ownerKeys;
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 j = i + 1; j < keys.length; ++j) {
                if (vm.addr(keys[j]) < vm.addr(keys[i])) (keys[i], keys[j]) = (keys[j], keys[i]);
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Push distribution and refunds (the relayer, through Multicall3)
    // ---------------------------------------------------------------------------------------------

    /// @dev Four holders claim for themselves first: three proofless, one with its proof. The picks are leaves 7,
    ///      1000, 4321 and 2500 of the full 6,338-holder cohort, scaled to a smaller rehearsal cohort's size.
    function _selfClaims(Leaf[] memory leaves) internal returns (bytes[] memory expectFail) {
        expectFail = new bytes[](leaves.length);
        uint256[4] memory picks = [uint256(7), 1000, 4321, 2500];
        for (uint256 k; k < 4; ++k) {
            picks[k] = picks[k] * leaves.length / FULL_SCALE_HOLDERS;
            for (uint256 j; j < k; ++j) {
                require(picks[j] != picks[k], "the cohort is too small for four distinct self-claims");
            }
        }
        for (uint256 k; k < 3; ++k) {
            Leaf memory l = leaves[picks[k]];
            vm.prank(l.account);
            vault.claimProRata();
            expectFail[l.index] = abi.encodeWithSelector(MigrationVault.AlreadyClaimedAccount.selector, l.account);
        }
        Leaf memory withProof = leaves[picks[3]];
        vm.prank(withProof.account);
        vault.claim(withProof.index, withProof.account, withProof.amount, withProof.proof);
        expectFail[withProof.index] = abi.encodeWithSelector(MigrationVault.AlreadyClaimed.selector, withProof.index);
    }

    function _push(Leaf[] memory leaves, bytes[] memory expectFail) internal returns (PushStats memory s) {
        for (uint256 start; start < leaves.length; start += CLAIMS_PER_BATCH) {
            uint256 n = Math.min(CLAIMS_PER_BATCH, leaves.length - start);
            IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](n);
            for (uint256 j; j < n; ++j) {
                Leaf memory l = leaves[start + j];
                calls[j] = IMulticall3.Call3(
                    address(vault), true, abi.encodeCall(MigrationVault.claim, (l.index, l.account, l.amount, l.proof))
                );
            }
            IMulticall3.Result[] memory results = _send(calls, s);
            for (uint256 j; j < n; ++j) {
                if (results[j].success) continue;
                s.failures += 1;
                if (expectFail.length != 0) {
                    require(
                        keccak256(results[j].returnData) == keccak256(expectFail[start + j]),
                        "an unexpected claim failed"
                    );
                }
            }
        }
    }

    function _pushRefunds() internal returns (PushStats memory s) {
        for (uint256 start; start < holders.length; start += REFUNDS_PER_BATCH) {
            uint256 n = Math.min(REFUNDS_PER_BATCH, holders.length - start);
            IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](n);
            for (uint256 j; j < n; ++j) {
                calls[j] = IMulticall3.Call3(
                    address(vault), false, abi.encodeCall(MigrationVault.refund, (holders[start + j]))
                );
            }
            _send(calls, s);
        }
    }

    /// @dev One relayer transaction: cold-priced, measured with its intrinsic and calldata gas (the larger of
    ///      the standard cost and the EIP-7623 calldata floor), and checked against both per-tx limits.
    function _send(IMulticall3.Call3[] memory calls, PushStats memory s)
        internal
        returns (IMulticall3.Result[] memory results)
    {
        bytes memory data = abi.encodeCall(IMulticall3.aggregate3, (calls));
        rvm.cool(address(vault));
        rvm.cool(address(v2));
        rvm.cool(V1);
        rvm.cool(MULTICALL3);
        vm.prank(relayer);
        (bool ok, bytes memory ret, uint256 used) = _call(MULTICALL3, data);
        require(ok, "a relayer batch reverted");
        results = abi.decode(ret, (IMulticall3.Result[]));
        uint256 tokens;
        for (uint256 i; i < data.length; ++i) {
            tokens += data[i] == 0 ? 1 : 4;
        }
        uint256 txGas = Math.max(21_000 + 4 * tokens + used, 21_000 + 10 * tokens);
        require(txGas < GAS_CAP && data.length < CALLDATA_CAP, "a relayer batch exceeds a per-tx limit");
        s.batches += 1;
        s.calls += calls.length;
        s.execGas += used;
        s.totalTxGas += txGas;
        s.maxTxGas = Math.max(s.maxTxGas, txGas);
        s.totalBytes += data.length;
        s.maxBytes = Math.max(s.maxBytes, data.length);
        s.l1FeeUpperWei += IGasPriceOracle(GAS_PRICE_ORACLE).getL1FeeUpperBound(data.length + 100);
    }

    function _assertEveryoneRefunded() internal view {
        for (uint256 i; i < holders.length; ++i) {
            require(IERC20(V1).balanceOf(holders[i]) == amounts[i], "a holder did not get its exact v1 back");
        }
        require(
            IERC20(V1).balanceOf(address(vault)) == 0 && v2.totalSupply() == 0
                && IERC20(V1).totalSupply() == v1SupplyBefore,
            "refund custody"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Trades through the hook (this contract is a minimal v4 router)
    // ---------------------------------------------------------------------------------------------

    struct Trade {
        PoolKey key;
        SwapParams params;
    }

    function _trades(PoolKey memory key, Leaf[] memory leaves) internal returns (uint256[4] memory fees) {
        // v2 for the sells comes from the largest holder, so the trades change no supply.
        uint256 largest;
        for (uint256 i; i < leaves.length; ++i) {
            if (leaves[i].amount > leaves[largest].amount) largest = i;
        }
        vm.prank(leaves[largest].account);
        require(v2.transfer(address(this), 50_000_000 ether), "v2 for the sells");
        fees[0] = _trade(key, true, -int256(1 ether));
        fees[1] = _trade(key, false, -int256(10_000_000 ether));
        fees[2] = _trade(key, true, int256(10_000_000 ether));
        fees[3] = _trade(key, false, int256(0.2 ether));
    }

    function _trade(PoolKey memory key, bool buyV2, int256 amount) internal returns (uint256 taken) {
        bool zeroForOne = buyV2 == (key.currency0 == WETH);
        SwapParams memory sp = SwapParams(zeroForOne, amount, zeroForOne ? MIN_SQRT_PRICE_PLUS_1 : V3_MAX_SQRT_MINUS_1);
        bool exactIn = amount < 0;
        address feeCurrency = exactIn == zeroForOne ? key.currency1 : key.currency0;
        uint256 takenBefore = hook.totalTaken(feeCurrency);
        int256 delta = abi.decode(IPoolManager(POOL_MANAGER).unlock(abi.encode(Trade(key, sp))), (int256));
        int128 unspecified = feeCurrency == key.currency0 ? LaunchMath.amount0(delta) : LaunchMath.amount1(delta);
        taken = hook.totalTaken(feeCurrency) - takenBefore;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 traderSide = uint256(uint128(unspecified < 0 ? -unspecified : unspecified));
        uint256 poolSide = exactIn ? traderSide + taken : traderSide - taken;
        require(taken != 0 && taken == (poolSide * 15_000) / 1_000_000, "the hook did not take exactly 1.5%");
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == POOL_MANAGER, "only the PoolManager");
        Trade memory t = abi.decode(data, (Trade));
        int256 delta = IPoolManager(POOL_MANAGER).swap(t.key, t.params, bytes(""));
        _settleSide(t.key.currency0, LaunchMath.amount0(delta));
        _settleSide(t.key.currency1, LaunchMath.amount1(delta));
        return abi.encode(delta);
    }

    function _settleSide(address currency, int128 amount) internal {
        if (amount < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 owed = uint256(uint128(-amount));
            if (currency == WETH) {
                vm.deal(address(this), owed);
                (bool ok,) = WETH.call{value: owed}(abi.encodeWithSignature("deposit()"));
                require(ok, "wrap");
            }
            IPoolManager(POOL_MANAGER).sync(currency);
            require(IERC20(currency).transfer(POOL_MANAGER, owed), "pay the manager");
            IPoolManager(POOL_MANAGER).settle();
        } else if (amount > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            IPoolManager(POOL_MANAGER).take(currency, address(this), uint256(uint128(amount)));
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Inputs and the result file
    // ---------------------------------------------------------------------------------------------

    function _loadCohort() internal {
        // The fs sandbox is kit/: copy the rehearsal's cohort.json there (kit/rehearse.py reads the same file).
        string memory c = rvm.readFile(rvm.envOr("SURPLUS_COHORT", string("kit/output/cohort/cohort.json")));
        address[] memory a = rvm.parseJsonAddressArray(c, ".accounts");
        uint256[] memory amt = rvm.parseJsonUintArray(c, ".amounts");
        require(a.length == amt.length && a.length == rvm.parseJsonUint(c, ".eligibleCount"), "cohort shape");
        for (uint256 i; i < a.length; ++i) {
            holders.push(a[i]);
            amounts.push(amt[i]);
            cohortTotal += amt[i];
        }
        require(cohortTotal == rvm.parseUint(rvm.parseJsonString(c, ".eligibleTotal")), "cohort total");
    }

    function _tree() internal view returns (bytes32 root, uint256 total, Leaf[] memory leaves) {
        string memory json = rvm.readFile(rvm.envOr("SURPLUS_TREE", string("")));
        root = rvm.parseBytes32(rvm.parseJsonString(json, ".root"));
        total = rvm.parseUint(rvm.parseJsonString(json, ".total"));
        leaves = abi.decode(rvm.parseJsonTypeArray(json, ".leaves", LEAF_TYPE), (Leaf[]));
    }

    /// @dev slot0 packs sqrtPriceX96 (160) | tick (24) | protocolFee (24) | lpFee (24).
    function _lpFee(bytes32 poolId) internal view returns (uint256) {
        uint256 slot0 = uint256(IExtsloadFull(POOL_MANAGER).extsload(keccak256(abi.encode(poolId, uint256(6)))));
        return (slot0 >> 208) & 0xFFFFFF;
    }

    function _sqrtPrice(bytes32 poolId) internal view returns (uint160) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(uint256(IExtsloadFull(POOL_MANAGER).extsload(keccak256(abi.encode(poolId, uint256(6))))));
    }

    function _writeResult(
        Launch memory l,
        PushStats memory s,
        uint256 total,
        uint256 v2SupplyAfterLaunch,
        uint256[4] memory fees
    ) internal {
        string memory o = "result";
        rvm.serializeUint(o, "block", block.number);
        rvm.serializeUint(o, "holders", holders.length);
        rvm.serializeUint(o, "v1DepositedWei", cohortTotal);
        rvm.serializeUint(o, "v1SupplyWei", v1SupplyBefore);
        rvm.serializeUint(o, "totalClaimableWei", total);
        rvm.serializeUint(o, "launchBatchExecGas", l.batchGas);
        rvm.serializeUint(o, "simulatedWethRaisedWei", l.simRaised);
        rvm.serializeUint(o, "minWethOutWei", l.p.minWethOut);
        rvm.serializeUint(o, "v2BudgetWei", l.budget);
        rvm.serializeUint(o, "wethRaisedWei", settler.wethRaised());
        rvm.serializeUint(o, "wethFromV3TailWei", l.tailWeth);
        rvm.serializeUint(o, "v1SoldOnV3TailWei", l.p.tailIn);
        rvm.serializeUint(o, "oldPoolSqrtPriceBefore", l.oldSqrtBefore);
        rvm.serializeUint(o, "oldPoolSqrtPriceAfter", l.oldSqrtAfter);
        rvm.serializeUint(o, "wethSeededWei", settler.wethSeeded());
        rvm.serializeUint(o, "v2SeededWei", settler.v2Seeded());
        rvm.serializeUint(o, "successorSqrtPriceX96", LaunchMath.sqrtPriceAtTick(l.p.openTick));
        rvm.serializeUint(o, "wethLiquidity", settler.wethLiquidity());
        rvm.serializeUint(o, "firstPositionId", settler.firstPositionId());
        rvm.serializeUint(o, "positionCount", settler.positionCount());
        rvm.serializeUint(o, "v2SupplyAfterLaunchWei", v2SupplyAfterLaunch);
        rvm.serializeUint(o, "pushBatches", s.batches);
        rvm.serializeUint(o, "pushCalls", s.calls);
        rvm.serializeUint(o, "pushSkipped", s.failures);
        rvm.serializeUint(o, "pushExecGas", s.execGas);
        rvm.serializeUint(o, "pushTotalTxGas", s.totalTxGas);
        rvm.serializeUint(o, "baseFeeWei", block.basefee);
        rvm.serializeUint(o, "successorLpFeePips", _lpFee(keccak256(abi.encode(l.p.newKey))));
        rvm.serializeUint(o, "pushMaxTxGas", s.maxTxGas);
        rvm.serializeUint(o, "pushTotalBytes", s.totalBytes);
        rvm.serializeUint(o, "pushMaxTxBytes", s.maxBytes);
        rvm.serializeUint(o, "pushL1FeeUpperWei", s.l1FeeUpperWei);
        rvm.serializeUint(o, "feeExactInBuy", fees[0]);
        rvm.serializeUint(o, "feeExactInSell", fees[1]);
        rvm.serializeUint(o, "feeExactOutBuy", fees[2]);
        rvm.serializeUint(o, "feeExactOutSell", fees[3]);
        rvm.serializeAddress(o, "v2", address(v2));
        rvm.serializeAddress(o, "safe", address(safe));
        string memory json = rvm.serializeAddress(o, "vault", address(vault));
        rvm.writeFile("kit/output/rehearsal/result.json", json);
    }
}

interface SurplusTokenV2Like is IERC20 {
    function cap() external view returns (uint256);
}
