// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MigrationVault} from "@surplus/migration/src/MigrationVault.sol";
import {ClaimTree} from "@surplus/migration-tools/src/ClaimTree.sol";
import {SurplusTokenV2} from "@surplus/token-v2/src/SurplusTokenV2.sol";
import {MigrationSettler} from "../../src/MigrationSettler.sol";
import {IPositionManager, PoolKey} from "../../src/LaunchInterfaces.sol";
import {LaunchMath} from "../../src/LaunchMath.sol";
import {Test} from "../Base.t.sol";
import {HookDouble} from "../utils/HookDouble.sol";
import {LadderMirror} from "../utils/LadderMirror.sol";

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ISafe {
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
    function masterCopy() external view returns (address);
    function getThreshold() external view returns (uint256);
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

interface IExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
}

/**
 * @dev The launch path on the pinned Base fork. The Safe 1.4.1 proxy, MultiSendCallOnly, PoolManager,
 *      PositionManager, Permit2, the Doppler pool and the v3 tail are all the real deployed contracts. The
 *      vault, token and settler are the monorepo sources. Only the successor hook is a double (HookDouble,
 *      etched at an address carrying the 0x2044 flags); the real hook is proven in contracts/fee-hook. The
 *      cohort is the ten largest EOA holders at the pin, each depositing its live balance at the fork block.
 */
abstract contract LaunchForkBase is Test {
    using SafeCast for uint256;

    address internal constant V1 = 0xC52aeDec3374422d7510E294cfAa90799595CBa3;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant V3_TAIL = 0xbCf23F30a90f6D7c288fACdc932fF8F8B68b0f30;
    address internal constant SAFE_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant MULTISEND_CALL_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address internal constant OLD_HOOK = 0xbB7784A4d481184283Ed89619A3e3ed143e1Adc0;
    bytes32 internal constant OLD_POOL_ID = 0xfc25fdd217e288d03a877f0b7d49e0bbe52b2288c88de929125062569fc7eb2a;
    uint24 internal constant OLD_FEE = 0x800000; // the dynamic-fee flag: Doppler's hook sets the fee
    int24 internal constant OLD_SPACING = 200;

    // Runtime code hashes at the pin (kit/evidence/00-pin.json): a changed contract fails setUp, not a test.
    bytes32 internal constant SAFE_SINGLETON_HASH = 0xb1f926978a0f44a2c0ec8fe822418ae969bd8c3f18d61e5103100339894f81ff;
    bytes32 internal constant SAFE_FACTORY_HASH = 0x50c3cdc4074750a7a974204a716c999edd37482f907608d960b2b025ee0b3317;
    bytes32 internal constant MULTISEND_HASH = 0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939;
    bytes32 internal constant POOL_MANAGER_HASH = 0x83b2af6e9f3158defc2811cbcb0db71ecf8b2ba2abea39c39e370ac5c6f43eb6;
    bytes32 internal constant POSITION_MANAGER_HASH =
        0x243f9e091ddf11c7c04e28059fdbbf1bab82b72d414fafb8e096c097aaeb622a;
    bytes32 internal constant PERMIT2_HASH = 0xa67739abc3ede9dbdc0491636c67d6a14ac07fab9030c3f509b1eb7b11dff8ed;
    bytes32 internal constant V3_TAIL_HASH = 0x4e9765e7a79b52a8a05580258d5113801c67829c8c5debd9eb88edfca177a771;
    bytes32 internal constant OLD_HOOK_HASH = 0x317314fa00365686fa78baafcd62d23ca4383b7d01a704ef5c600b8f8548e897;

    uint256 internal constant DEFAULT_PIN = 51_935_583;
    /// @dev v4 PoolManager storage: `mapping(PoolId => Pool.State) _pools` at slot 6; liquidity is slot0 + 3.
    uint256 internal constant POOLS_SLOT = 6;
    uint256 internal constant LIQUIDITY_OFFSET = 3;

    // Launch parameters (kit params.json; §1 fixed decisions: 0.30% LP, 1:1, pro-rata on).
    uint24 internal constant LP_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    /// @dev The v2 side copies the old pool's v1 ladder; adjacent segments within 1% of liquidity merge (kit seed).
    uint256 internal constant MIRROR_MERGE_BPS = 100;
    uint160 internal constant V3_MAX_SQRT_MINUS_1 = 1461446703485210103287273052203988822378723970341;
    uint256 internal constant V2_CAP = 100_000_000_000 ether; // rehearsal placeholder (§6.2 TBD)
    uint256 internal constant RATE_BPS = 10_000;

    // Public, deterministic, throwaway test signer seeds (§6.1 rehearsal default: 2-of-3).
    uint256 internal constant KEY_A = 0xA11CE;
    uint256 internal constant KEY_B = 0xB0B;
    uint256 internal constant KEY_C = 0xCA401;
    address internal constant OUTSIDER = address(0xBAD);
    /// @dev Any address whose low 14 bits are 0x2044: BEFORE_INITIALIZE | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA.
    address internal constant HOOK = address((uint160(0x5E11E7) << 136) | 0x2044);

    ISafe internal safe;
    /// @dev The hook the successor key names: the double etched at HOOK, unless a test deploys the real one.
    address internal successorHook = HOOK;
    SurplusTokenV2 internal v2;
    MigrationVault internal vault;
    MigrationSettler internal settler;
    address[] internal holders;
    uint256 internal total;
    uint256 internal v1SupplyBefore;

    function setUp() public virtual {
        require(block.chainid == 8453, "not a Base fork");
        require(block.number == vm.envOr("SURPLUS_FORK_BLOCK", DEFAULT_PIN), "fork block is not the pin");
        require(
            SAFE_SINGLETON.codehash == SAFE_SINGLETON_HASH && SAFE_FACTORY.codehash == SAFE_FACTORY_HASH
                && MULTISEND_CALL_ONLY.codehash == MULTISEND_HASH && POOL_MANAGER.codehash == POOL_MANAGER_HASH
                && POSITION_MANAGER.codehash == POSITION_MANAGER_HASH && PERMIT2.codehash == PERMIT2_HASH
                && V3_TAIL.codehash == V3_TAIL_HASH && OLD_HOOK.codehash == OLD_HOOK_HASH,
            "runtime code drift at the pin"
        );
        require(keccak256(abi.encode(_oldKey())) == OLD_POOL_ID, "old PoolKey drift");
        _deploySafe();
        holders = _cohort();
        v1SupplyBefore = IERC20(V1).totalSupply();
    }

    // ---------------------------------------------------------------------------------------------
    // Launch fixture
    // ---------------------------------------------------------------------------------------------

    /// @dev Deploys token → vault → settler → hook (the kit's deploy order), deposits the cohort and commits the
    ///      root through the Safe. `gatedHook` false models a hook without the initializer gate.
    function _launchSetup(bool v2BelowWeth, bool gatedHook) internal {
        v2 = _deployToken(v2BelowWeth);
        vault = new MigrationVault(
            IERC20(V1),
            IERC20(address(v2)),
            block.timestamp + 2 days,
            block.timestamp + 5 days,
            7 days,
            180 days,
            RATE_BPS,
            true,
            address(safe)
        );
        settler = new MigrationSettler(
            MigrationSettler.Config({
                poolManager: POOL_MANAGER,
                positionManager: POSITION_MANAGER,
                permit2: PERMIT2,
                safe: address(safe),
                v1: V1,
                weth: WETH,
                v2: address(v2),
                v3Tail: V3_TAIL,
                oldPoolId: OLD_POOL_ID,
                lpFee: LP_FEE,
                tickSpacing: TICK_SPACING,
                feeRecipient: address(safe) // §6.4 rehearsal default
            })
        );
        vm.etch(HOOK, address(new HookDouble(address(settler), address(safe), gatedHook)).code);
        _depositAll();
        _commit();
    }

    /// @dev The v2 proxy at a CREATE2 address on the requested side of WETH, so both pool orientations are proven.
    function _deployToken(bool belowWeth) internal returns (SurplusTokenV2 token) {
        SurplusTokenV2 implementation = new SurplusTokenV2();
        bytes memory init =
            abi.encodeCall(SurplusTokenV2.initialize, ("Test-only SURPLUS v2", "TV2", V2_CAP, address(safe)));
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(implementation), init)));
        for (uint256 salt;; ++salt) {
            bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), initCodeHash));
            // forge-lint: disable-next-line(unsafe-typecast)
            address predicted = address(uint160(uint256(h)));
            if ((predicted < WETH) != belowWeth) continue;
            token = SurplusTokenV2(address(new ERC1967Proxy{salt: bytes32(salt)}(address(implementation), init)));
            require(address(token) == predicted && token.totalSupply() == 0, "token deployment");
            return token;
        }
    }

    function _deploySafe() internal {
        address[] memory owners = new address[](3);
        owners[0] = vm.addr(KEY_A);
        owners[1] = vm.addr(KEY_B);
        owners[2] = vm.addr(KEY_C);
        address proxy = ISafeProxyFactory(SAFE_FACTORY)
            .createProxyWithNonce(
                SAFE_SINGLETON,
                abi.encodeCall(
                    ISafe.setup, (owners, 2, address(0), "", address(0), address(0), 0, payable(address(0)))
                ),
                0x5ec7
            );
        safe = ISafe(proxy);
        require(safe.masterCopy() == SAFE_SINGLETON && safe.getThreshold() == 2 && safe.nonce() == 0, "Safe");
    }

    /// @dev The ten largest EOA holders of v1 at the pin (fullscale-260929 cohort/source/classes.json).
    function _cohort() internal pure returns (address[] memory c) {
        c = new address[](10);
        c[0] = 0x7d0E09bf462a4fbc020616b25c1De6Dfc461b262;
        c[1] = 0xff8CE9674b5B5F731D030b0FFf6d927E510DAe05;
        c[2] = 0xeD49Cd4a93BD39FA7bC02e7BC2b4493Df047401E;
        c[3] = 0x6d3369D9BafDE58EC5928A381d454590783D8d1A;
        c[4] = 0x9CD3F08E46F1A6116e35585120F39f7BeAA2E25d;
        c[5] = 0x3Fbc4861A4Cb1Ef34b06059765308D4A03266A93;
        c[6] = 0x49A054B7B597185a41c9F972cC71a1D15B51a56a;
        c[7] = 0x41f376428dE2a1c0d7ce6e0Fa2Fe3c2D4D0bAe72;
        c[8] = 0x054BA12713290eF5B9236E55944713c0Edeb4Cf4;
        c[9] = 0xC830a13e213a0c57B0266f1aEDa5171c8eD3fD9D;
    }

    function _depositAll() internal {
        for (uint256 i; i < holders.length; ++i) {
            address h = holders[i];
            uint256 balance = IERC20(V1).balanceOf(h);
            require(balance != 0 && h.code.length == 0, "cohort holder has no v1 or is not an EOA");
            vm.startPrank(h);
            require(IERC20(V1).approve(address(vault), balance), "approve");
            vault.deposit(balance);
            vm.stopPrank();
            total += balance;
        }
        require(IERC20(V1).balanceOf(address(vault)) == total && vault.totalDepositedV1() == total, "custody");
    }

    function _commit() internal {
        vm.warp(vault.DEPOSIT_DEADLINE() + 1);
        bytes32[] memory leaves = new bytes32[](holders.length);
        for (uint256 i; i < holders.length; ++i) {
            address h = holders[i];
            leaves[i] = ClaimTree.leaf(i, h, ((vault.credited(h) - vault.withdrawn(h)) * RATE_BPS) / 10_000);
        }
        bytes32 root = ClaimTree.rootOf(leaves);
        _safeExec(address(vault), abi.encodeCall(MigrationVault.commitRoot, (root, total)));
        require(vault.root() == root && vault.totalClaimable() == total, "root commit");
    }

    // ---------------------------------------------------------------------------------------------
    // The launch batch: simulate, then sign
    // ---------------------------------------------------------------------------------------------

    function _oldKey() internal pure returns (PoolKey memory) {
        return PoolKey(WETH, V1, OLD_FEE, OLD_SPACING, OLD_HOOK);
    }

    function _newKey() internal view returns (PoolKey memory) {
        bool v2First = address(v2) < WETH;
        return PoolKey(v2First ? address(v2) : WETH, v2First ? WETH : address(v2), LP_FEE, TICK_SPACING, successorHook);
    }

    /// @dev Unsigned params: v2 opens at v1's pre-sale price rounded to the successor grid (at 1:1 every migrator keeps
    ///      its value, within half a tick spacing), the v2 side copies the v1 the old pool holds above its price, and
    ///      10% of the v1 sells on the v3 tail, the rest on the Doppler pool (the fullscale-0928 split rule).
    function _params() internal view returns (MigrationSettler.Params memory p) {
        p.oldKey = _oldKey();
        p.v1In = total;
        p.tailIn = total / 10;
        p.tailLimit = V3_MAX_SQRT_MINUS_1;
        p.newKey = _newKey();
        bool v2First = address(v2) < WETH;
        int24 seamOld = _seamOld();
        // The old pool prices v1 per WETH (WETH is its currency0); the successor quotes the inverse when v2 sorts first.
        p.openTick = v2First ? -seamOld : seamOld;
        (p.v2Ranges,) = LadderMirror.mirror(
            POOL_MANAGER, OLD_POOL_ID, OLD_SPACING, TICK_SPACING, seamOld, v2First, MIRROR_MERGE_BPS
        );
    }

    /// @dev The opening tick in the old pool's orientation: its current tick rounded to the successor grid, half up.
    function _seamOld() internal view returns (int24) {
        (, int24 oldTick) = LadderMirror.slot0(POOL_MANAGER, OLD_POOL_ID);
        return LadderMirror.toGrid(oldTick, TICK_SPACING);
    }

    /// @dev The v1 the old pool holds above its price right now: what the v2 side copies.
    function _v1AboveOldPrice() internal view returns (uint256 v1Total) {
        (, v1Total) = LadderMirror.ladderBlocks(POOL_MANAGER, OLD_POOL_ID, OLD_SPACING, MIRROR_MERGE_BPS);
    }

    /// @dev What the signers do before signing (kit RUNBOOK): run the batch on a fork with no floor and the
    ///      whole remaining cap as budget, record the result, and discard the state.
    function _simulate(MigrationSettler.Params memory p) internal returns (uint256 raised, uint256 v2Used) {
        uint256 snapshot = vm.snapshotState();
        uint256 minWethOut = p.minWethOut;
        p.minWethOut = 0;
        (bool ok, bytes memory ret) = _launch(p, V2_CAP - total);
        require(ok && abi.decode(ret, (bool)), "the simulation must launch");
        raised = settler.wethRaised();
        v2Used = settler.v2Seeded();
        p.minWethOut = minWethOut;
        require(vm.revertToState(snapshot), "revert to the pre-simulation state");
    }

    /// @dev §4.4: minWethOut = simulated WETH × 0.995; v2 budget = the simulated v2 side + 10 wei. The v2 side is fixed
    ///      by the signed ranges, not by the sale, so it needs no drift margin.
    function _signed()
        internal
        returns (MigrationSettler.Params memory p, uint256 v2Budget, uint256 simRaised, uint256 simV2)
    {
        p = _params();
        (simRaised, simV2) = _simulate(p);
        p.minWethOut = (simRaised * 995) / 1000;
        v2Budget = simV2 + 10;
    }

    /// @dev ONE Safe transaction, DELEGATECALL to the official MultiSendCallOnly: back the vault, activate,
    ///      release v1 to the settler, mint the LP budget to it, settle. Claims and the successor pool go live
    ///      in the same block, so no holder can claim v2 while it has no pool.
    function _batch(MigrationSettler.Params memory p, uint256 v2Budget) internal view returns (bytes memory) {
        return abi.encodeWithSignature(
            "multiSend(bytes)",
            abi.encodePacked(
                _packed(address(v2), abi.encodeCall(SurplusTokenV2.mint, (address(vault), total))),
                _packed(address(vault), abi.encodeCall(MigrationVault.activateClaims, ())),
                _packed(
                    address(vault), abi.encodeCall(MigrationVault.withdrawV1ForSettlement, (address(settler), total))
                ),
                _packed(address(v2), abi.encodeCall(SurplusTokenV2.mint, (address(settler), v2Budget))),
                _packed(address(settler), abi.encodeCall(MigrationSettler.settle, (p)))
            )
        );
    }

    function _packed(address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), to, uint256(0), uint256(data.length), data);
    }

    function _launch(MigrationSettler.Params memory p, uint256 v2Budget) internal returns (bool, bytes memory) {
        return _safeCall(MULTISEND_CALL_ONLY, _batch(p, v2Budget), 1);
    }

    /// @dev The batch's first four steps executed by the Safe one call at a time, so a test can capture the exact
    ///      revert of `settle` (inside the Safe batch it surfaces only as GS013).
    function _stepsAsSafe(uint256 v2Budget) internal {
        vm.startPrank(address(safe));
        v2.mint(address(vault), total);
        vault.activateClaims();
        vault.withdrawV1ForSettlement(address(settler), total);
        v2.mint(address(settler), v2Budget);
        vm.stopPrank();
    }

    function _settleAsSafe(MigrationSettler.Params memory p) internal returns (bytes memory err) {
        vm.prank(address(safe));
        try settler.settle(p) {
            revert("settle was expected to revert");
        } catch (bytes memory reason) {
            err = reason;
        }
    }

    /// @dev A failed batch must leave nothing half-done: nothing minted, activated or released; nonce unchanged.
    function _expectBatchReverts(MigrationSettler.Params memory p, uint256 v2Budget) internal {
        uint256 nonceBefore = safe.nonce();
        (bool ok, bytes memory ret) = _launch(p, v2Budget);
        require(!ok && keccak256(ret) == keccak256(abi.encodeWithSignature("Error(string)", "GS013")), "not GS013");
        require(
            !vault.claimsActive() && v2.totalSupply() == 0 && IERC20(V1).balanceOf(address(vault)) == total
                && IERC20(V1).balanceOf(address(settler)) == 0 && safe.nonce() == nonceBefore,
            "a failed batch left state behind"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Safe
    // ---------------------------------------------------------------------------------------------

    function _safeCall(address to, bytes memory data, uint8 operation) internal returns (bool ok, bytes memory ret) {
        return _safeCallOn(safe, to, data, operation);
    }

    /// @dev Signed by KEY_A and KEY_B, so it works on any Safe those two can sign for.
    function _safeCallOn(ISafe target, address to, bytes memory data, uint8 operation)
        internal
        returns (bool ok, bytes memory ret)
    {
        bytes32 hash = _txHash(target, to, data, operation);
        (uint256 first, uint256 second) = vm.addr(KEY_A) < vm.addr(KEY_B) ? (KEY_A, KEY_B) : (KEY_B, KEY_A);
        bytes memory signatures = abi.encodePacked(_sign(first, hash), _sign(second, hash));
        (ok, ret) = address(target)
            .call(
                abi.encodeCall(
                    ISafe.execTransaction,
                    (to, 0, data, operation, 0, 0, 0, address(0), payable(address(0)), signatures)
                )
            );
    }

    function _txHash(ISafe target, address to, bytes memory data, uint8 operation) internal view returns (bytes32) {
        uint256 nonce = target.nonce();
        return target.getTransactionHash(to, 0, data, operation, 0, 0, 0, address(0), address(0), nonce);
    }

    function _safeExec(address to, bytes memory data) internal {
        uint256 nonceBefore = safe.nonce();
        (bool ok, bytes memory ret) = _safeCall(to, data, 0);
        require(ok && abi.decode(ret, (bool)) && safe.nonce() == nonceBefore + 1, "Safe transaction failed");
    }

    function _sign(uint256 key, bytes32 hash) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash);
        return abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------------------------------------
    // After the launch: what the batch and the launch contract must both leave behind
    // ---------------------------------------------------------------------------------------------

    function _assertLaunched(MigrationSettler.Params memory p, uint256 v2Budget, uint256 simRaised) internal {
        (bool backed, uint256 v2Balance, uint256 claimable, uint256 custody, bool active,) = vault.verifySettlement();
        assertTrue(backed && active && v2Balance == total && claimable == total && custody == 0, "vault after batch");

        uint256 raised = settler.wethRaised();
        assertEq(raised, simRaised, "execution diverged from the signed simulation");
        assertTrue(raised >= p.minWethOut, "sale below the signed floor");
        assertTrue(
            IERC20(V1).balanceOf(address(settler)) == 0 && IERC20(V1).balanceOf(address(safe)) == 0
                && IERC20(V1).totalSupply() == v1SupplyBefore,
            "v1 custody after the sale"
        );
        assertEq(
            settler.wethSeeded() + IERC20(WETH).balanceOf(address(safe)),
            raised,
            "every WETH wei raised is in the pool or back in the Safe"
        );
        assertTrue(raised - settler.wethSeeded() <= raised / 100_000, "the WETH side holds what the sale raised");
        assertEq(IERC20(WETH).balanceOf(address(settler)), 0, "WETH left in the settler");
        assertEq(v2.totalSupply(), total + v2Budget, "v2 supply = backing + LP budget");
        assertEq(v2.balanceOf(address(safe)), v2Budget - settler.v2Seeded(), "unused v2 budget back in the Safe");
        assertEq(v2.balanceOf(address(settler)), 0, "v2 left in the settler");

        (uint160 sqrtPriceX96, uint24 lpFee, uint128 liq) = _poolState(keccak256(abi.encode(p.newKey)));
        assertEq(sqrtPriceX96, LaunchMath.sqrtPriceAtTick(p.openTick), "successor opened at the signed tick's price");
        assertEq(lpFee, LP_FEE, "successor LP fee");
        // At the opening tick only the side above the price is active: the WETH side when WETH is currency0, the v2
        // range starting at the open when v2 is.
        assertEq(liq, address(v2) < WETH ? _rangeAtOpen(p) : settler.wethLiquidity(), "active liquidity at the open");
        assertEq(settler.positionCount(), p.v2Ranges.length + 1, "one LP NFT per side position");
        for (uint256 i; i < settler.positionCount(); ++i) {
            assertEq(
                IPositionManager(POSITION_MANAGER).ownerOf(settler.firstPositionId() + i),
                address(safe),
                "LP NFT is Safe-owned"
            );
        }

        emit log_named_uint("cohort_v1_sold", total);
        emit log_named_uint("sale_weth_raised_wei", raised);
        emit log_named_uint("successor_weth_seeded_wei", settler.wethSeeded());
        emit log_named_uint("successor_v2_seeded", settler.v2Seeded());
        emit log_named_uint("successor_v2_ranges", p.v2Ranges.length);
        emit log_named_uint("v2_budget_minted", v2Budget);
        emit log_named_uint("weth_returned_to_safe_wei", IERC20(WETH).balanceOf(address(safe)));
        emit log_named_uint("v2_returned_to_safe", v2.balanceOf(address(safe)));
    }

    function _rangeAtOpen(MigrationSettler.Params memory p) internal pure returns (uint128) {
        for (uint256 i; i < p.v2Ranges.length; ++i) {
            if (p.v2Ranges[i].tickLower == p.openTick) return p.v2Ranges[i].liquidity;
        }
        revert("no v2 range starts at the open");
    }

    // ---------------------------------------------------------------------------------------------
    // v4 state
    // ---------------------------------------------------------------------------------------------

    function _poolState(bytes32 poolId) internal view returns (uint160 sqrtPriceX96, uint24 lpFee, uint128 liq) {
        bytes32 stateSlot = keccak256(abi.encode(poolId, POOLS_SLOT));
        uint256 slot0 = uint256(IExtsload(POOL_MANAGER).extsload(stateSlot));
        // slot0 packs sqrtPriceX96 (160) | tick (24) | protocolFee (24) | lpFee (24); both casts truncate on purpose.
        // forge-lint: disable-next-line(unsafe-typecast)
        sqrtPriceX96 = uint160(slot0);
        // forge-lint: disable-next-line(unsafe-typecast)
        lpFee = uint24(slot0 >> 208);
        bytes32 liquiditySlot = bytes32(uint256(stateSlot) + LIQUIDITY_OFFSET);
        // forge-lint: disable-next-line(unsafe-typecast)
        liq = uint128(uint256(IExtsload(POOL_MANAGER).extsload(liquiditySlot)));
    }

    function _sqrtPrice(bytes32 poolId) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,) = _poolState(poolId);
    }
}
