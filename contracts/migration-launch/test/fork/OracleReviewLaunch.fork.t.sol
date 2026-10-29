// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SurplusFeeHook} from "@surplus/fee-hook/src/SurplusFeeHook.sol";
import {MigrationSettler} from "../../src/MigrationSettler.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "../../src/LaunchInterfaces.sol";
import {LaunchMath} from "../../src/LaunchMath.sol";
import {LaunchForkBase} from "./LaunchForkBase.sol";
import {HookStandIn} from "../utils/HookStandIn.sol";

/// @dev A hook bound to the settler that declares the decided 1.5% but has no TREASURY getter, so nothing on chain
///      says where its fees go: only the settler's treasury read-back can stop it.
contract NoTreasuryHook {
    uint24 public constant FEE_PIPS = 15_000;
    address public immutable INITIALIZER;

    constructor(address initializer) {
        INITIALIZER = initializer;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return NoTreasuryHook.beforeInitialize.selector;
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, int256, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        return (NoTreasuryHook.afterSwap.selector, 0);
    }
}

/// @dev A hook bound to the settler and paying the Safe that declares a fee other than the decided 1.5%, so the
///      settler's FEE_PIPS comparison is exercised by a hook that answers it (HookStandIn has no such getter).
contract WrongFeeHook {
    address public immutable INITIALIZER;
    address public immutable TREASURY;
    uint24 public immutable FEE_PIPS;

    constructor(address initializer, address treasury, uint24 feePips) {
        INITIALIZER = initializer;
        TREASURY = treasury;
        FEE_PIPS = feePips;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return WrongFeeHook.beforeInitialize.selector;
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, int256, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        return (WrongFeeHook.afterSwap.selector, 0);
    }
}

/// @dev Spec §3.5 oracle review of the launch contracts: the fixture both suites below share. The REAL fee hook,
///      deployed as the kit deploys it: CREATE2 through the canonical deployer at the smallest salt whose address
///      carries exactly the 0x2044 flags, initializer = the settler, treasury = the Safe.
abstract contract RealHookFixture is LaunchForkBase {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function _deployRealHook() internal returns (SurplusFeeHook) {
        return _deployRealHook(address(safe));
    }

    function _deployRealHook(address treasury) internal returns (SurplusFeeHook deployed) {
        (address c0, address c1) = address(v2) < WETH ? (address(v2), WETH) : (WETH, address(v2));
        bytes memory init = abi.encodePacked(
            type(SurplusFeeHook).creationCode,
            abi.encode(POOL_MANAGER, treasury, address(settler), c0, c1, LP_FEE, TICK_SPACING)
        );
        bytes32 initHash = keccak256(init);
        for (uint256 s;; ++s) {
            bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, bytes32(s), initHash));
            // forge-lint: disable-next-line(unsafe-typecast)
            address candidate = address(uint160(uint256(h)));
            if ((uint160(candidate) & ((1 << 14) - 1)) != 0x2044) continue;
            (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(bytes32(s), init));
            require(ok && ret.length == 20 && candidate.code.length != 0, "CREATE2 deploy");
            return SurplusFeeHook(candidate);
        }
    }
}

/**
 * @dev Settler round 1, finding 2 (triage: kit/evidence/review/migration-launch-oracle.md). FAILS on b62393184.
 *      The settler promises it "can never open a pool without the 1.5% hook", but `_checkSuccessor` only checks
 *      the hook's flag bits, that it has code, and that INITIALIZER() names the settler: any hook bound to the
 *      settler passes, fee or no fee. The kit's own rehearsal stand-in (test/utils/HookStandIn.sol: the real
 *      hook's constructor and initializer gate, no fee) is such a hook. A launch whose deploy plan carried it
 *      opens the successor pool with no fee, and a pool's hook can never change. The second test is the same gap
 *      with the REAL hook deployed with the wrong treasury (the §6.4 fee recipient is a deploy parameter; a
 *      mistyped address deploys fine): accepted too, and every fee the pool ever charges goes to that address.
 *      The expected error is the check's existing WrongHook, spelled from its signature; a fix with a dedicated
 *      error updates it.
 */
contract SettlerOracleReviewForkTest is RealHookFixture {
    bytes4 internal constant WRONG_HOOK = bytes4(keccak256("WrongHook(address)"));

    function test_ORACLE_settler_AHookWithoutTheFeeIsRefused() public {
        _launchSetup(false, true);
        successorHook = address(_deployRealHook());
        (MigrationSettler.Params memory p, uint256 v2Budget,,) = _signed();
        _stepsAsSafe(v2Budget);

        // Control: the signed params, naming the real fee hook, settle.
        uint256 snapshot = vm.snapshotState();
        vm.prank(address(safe));
        settler.settle(p);
        assertTrue(settler.v2Seeded() != 0, "control: the real fee hook launches");
        require(vm.revertToState(snapshot), "restore");

        // The same params naming the stand-in, exactly as the kit's --rehearsal deploy plan builds it.
        address standIn = address((uint160(0x57A9D1) << 136) | 0x2044);
        vm.etch(
            standIn,
            address(
                new HookStandIn(
                    POOL_MANAGER,
                    address(safe),
                    address(settler),
                    p.newKey.currency0,
                    p.newKey.currency1,
                    LP_FEE,
                    TICK_SPACING
                )
            )
            .code
        );
        p.newKey.hooks = standIn;
        vm.prank(address(safe));
        (bool ok, bytes memory ret) = address(settler).call(abi.encodeCall(MigrationSettler.settle, (p)));
        assertTrue(
            !ok, "the settler opened the successor pool with a hook that charges no fee (the rehearsal stand-in)"
        );
        assertEq(keccak256(ret), keccak256(abi.encodeWithSelector(WRONG_HOOK, standIn)), "revert reason");
    }

    function test_ORACLE_settler_AHookDeclaringAnotherFeeIsRefused() public {
        _launchSetup(false, true);
        successorHook = address(_deployRealHook());
        (MigrationSettler.Params memory p, uint256 v2Budget,,) = _signed();
        _stepsAsSafe(v2Budget);

        // Bound to the settler and paying the Safe, but a 1% hook: only the fee comparison can stop it.
        address wrongFee = address((uint160(0xFEE1) << 136) | 0x2044);
        vm.etch(wrongFee, address(new WrongFeeHook(address(settler), address(safe), 10_000)).code);
        p.newKey.hooks = wrongFee;
        vm.prank(address(safe));
        (bool ok, bytes memory ret) = address(settler).call(abi.encodeCall(MigrationSettler.settle, (p)));
        assertTrue(!ok, "the settler opened the successor pool with a hook whose fee is not the decided 1.5%");
        assertEq(keccak256(ret), keccak256(abi.encodeWithSelector(WRONG_HOOK, wrongFee)), "revert reason");
    }

    function test_ORACLE_settler_AHookThatHidesItsTreasuryIsRefused() public {
        _launchSetup(false, true);
        successorHook = address(_deployRealHook());
        (MigrationSettler.Params memory p, uint256 v2Budget,,) = _signed();
        _stepsAsSafe(v2Budget);

        address hidden = address((uint160(0x7EA5) << 136) | 0x2044);
        vm.etch(hidden, address(new NoTreasuryHook(address(settler))).code);
        p.newKey.hooks = hidden;
        vm.prank(address(safe));
        (bool ok, bytes memory ret) = address(settler).call(abi.encodeCall(MigrationSettler.settle, (p)));
        assertTrue(!ok, "the settler opened the successor pool with a hook that does not say where its fees go");
        assertEq(keccak256(ret), keccak256(abi.encodeWithSelector(WRONG_HOOK, hidden)), "revert reason");
    }

    function test_ORACLE_settler_AFeeHookPayingAnotherTreasuryIsRefused() public {
        _launchSetup(false, true);
        successorHook = address(_deployRealHook());
        (MigrationSettler.Params memory p, uint256 v2Budget,,) = _signed();
        _stepsAsSafe(v2Budget);

        // The real fee hook, bound to the settler, but deployed with a mistyped fee recipient.
        SurplusFeeHook strayHook = _deployRealHook(OUTSIDER);
        assertEq(strayHook.INITIALIZER(), address(settler), "fixture: bound to the settler");
        assertEq(strayHook.TREASURY(), OUTSIDER, "fixture: its fees go to an outsider");
        p.newKey.hooks = address(strayHook);
        vm.prank(address(safe));
        (bool ok, bytes memory ret) = address(settler).call(abi.encodeCall(MigrationSettler.settle, (p)));
        assertTrue(!ok, "the settler opened the successor pool with a fee hook whose treasury is not the Safe");
        assertEq(keccak256(ret), keccak256(abi.encodeWithSelector(WRONG_HOOK, address(strayHook))), "revert reason");
    }
}

/**
 * @dev Fee hook round 2, finding 1 (triage: kit/evidence/review/fee-hook-oracle.md). On an exact-output swap the
 *      fee currency is the swap's INPUT, and afterSwap takes the fee from the PoolManager before the swapper has
 *      paid any of it in, so the take fails if the manager holds less of that currency than the fee. This
 *      measures where that starts on the pool the launch batch really opens (the real hook, the real v2 proxy,
 *      the settler's full-range seed), for sells and buys and both currency orders, by bisecting the exact-output
 *      size between "the take succeeds" and "the take fails". The probe never pays: its unlock callback reverts
 *      once swap() has returned, so it needs neither v2 nor WETH. It pins the NOT-A-DEFECT premise: only a single
 *      swap draining over 98% of the pool's output reserve can fail, and as a sale it would pay in more v2 than
 *      exists.
 */
contract HookExactOutputThresholdForkTest is RealHookFixture, IUnlockCallback {
    uint160 internal constant MIN_SQRT_PRICE_PLUS_1 = 4_295_128_740;
    uint160 internal constant MAX_SQRT_PRICE_MINUS_1 = 1461446703485210103287273052203988822378723970341;
    bytes4 internal constant HOOK_CALL_FAILED = bytes4(keccak256("HookCallFailed()"));
    bytes4 internal constant ERC20_TRANSFER_FAILED = bytes4(keccak256("ERC20TransferFailed()"));
    uint256 internal constant PPM = 1_000_000;

    /// @dev The unlock callback's exit once swap() has returned, i.e. once the hook's take succeeded.
    error TakeSucceeded(int256 delta);

    PoolKey internal key;

    function test_ExactOutputTakeFailsOnlyPast98Percent_V2AboveWeth() public {
        _measure(false);
    }

    function test_ExactOutputTakeFailsOnlyPast98Percent_V2BelowWeth() public {
        _measure(true);
    }

    function _measure(bool v2BelowWeth) internal {
        _launchSetup(v2BelowWeth, true);
        successorHook = address(_deployRealHook());
        (MigrationSettler.Params memory p, uint256 v2Budget,,) = _signed();
        (bool ok, bytes memory ret) = _launch(p, v2Budget);
        require(ok && abi.decode(ret, (bool)), "launch batch through the real hook");
        key = p.newKey;

        uint256 poolWeth = settler.wethSeeded();
        uint256 poolV2 = settler.v2Seeded();
        // v2 exists in no other v4 pool, so the launched pool's seed is all the v2 a take can draw on.
        assertEq(IERC20(address(v2)).balanceOf(POOL_MANAGER), poolV2, "the PoolManager's v2 is the launched seed");
        emit log_named_uint("pool WETH (wei)", poolWeth);
        emit log_named_uint("pool v2 = PoolManager v2 (wei)", poolV2);
        emit log_named_uint("PoolManager WETH, every Base v4 pool (wei)", IERC20(WETH).balanceOf(POOL_MANAGER));
        emit log_named_uint("v2 totalSupply (wei)", v2.totalSupply());

        // Exact-output SELL: v2 in (the fee currency), WETH out.
        (uint256 lo, uint256 hi, uint256 v2In) = _threshold(true, poolWeth);
        emit log_named_uint("sell: largest WETH-out share that fills (ppm of pool WETH)", lo);
        emit log_named_uint("sell: smallest WETH-out share whose take fails (ppm)", hi);
        emit log_named_uint("sell: v2 paid in at the largest fill (wei)", v2In);
        assertTrue(lo >= 980_000, "an exact-output sell below a 98% drain of the pool's WETH fails the hook's take");
        assertTrue(v2In > v2.totalSupply(), "a sell that fails the take needs less v2 than exists");

        // Exact-output BUY: WETH in (the fee currency), v2 out.
        uint256 wethIn;
        (lo, hi, wethIn) = _threshold(false, poolV2);
        emit log_named_uint("buy: largest v2-out share that fills (ppm of pool v2)", lo);
        emit log_named_uint("buy: smallest v2-out share whose take fails (ppm)", hi);
        emit log_named_uint("buy: WETH paid in at the largest fill (wei)", wethIn);
        assertTrue(lo >= 980_000, "an exact-output buy below a 98% drain of the pool's v2 fails the hook's take");
    }

    /// @return lo the largest exact-output size that still fills, in ppm of the pool's reserve of the output
    /// @return hi the smallest size whose take fails, in ppm (hi - lo <= 1)
    /// @return paidIn the fee currency the swapper owes at the largest size that fills
    function _threshold(bool sellV2, uint256 reserveOut) internal returns (uint256 lo, uint256 hi, uint256 paidIn) {
        uint256 fills = reserveOut / 2;
        // 99.999999%: past any threshold, and short of v4's int128 amount limits.
        uint256 fails = reserveOut - reserveOut / 100_000_000;
        (bool ok, int256 fill) = _tryExactOut(sellV2, fills);
        require(ok, "half the pool fills");
        (ok,) = _tryExactOut(sellV2, fails);
        require(!ok, "a 99.999999% drain fails the take");
        while (fails - fills > reserveOut / PPM) {
            uint256 mid = (fills + fails) / 2;
            (bool filled, int256 d) = _tryExactOut(sellV2, mid);
            if (filled) {
                fills = mid;
                fill = d;
            } else {
                fails = mid;
            }
        }
        lo = fills * PPM / reserveOut;
        hi = (fails * PPM + reserveOut - 1) / reserveOut;
        int128 owed = (sellV2 == (key.currency0 == address(v2))) ? LaunchMath.amount0(fill) : LaunchMath.amount1(fill);
        require(owed < 0, "the swapper owes the input");
        // forge-lint: disable-next-line(unsafe-typecast)
        paidIn = uint256(uint128(-owed));
    }

    /// @return filled whether swap() returned, i.e. the hook's take succeeded
    /// @return delta the swapper's BalanceDelta when it did
    function _tryExactOut(bool sellV2, uint256 amountOut) internal returns (bool filled, int256 delta) {
        // The input currency is currency0 when selling v2 that sorts first, or buying v2 that sorts second.
        bool zeroForOne = sellV2 == (key.currency0 == address(v2));
        SwapParams memory sp = SwapParams(
            zeroForOne, SafeCast.toInt256(amountOut), zeroForOne ? MIN_SQRT_PRICE_PLUS_1 : MAX_SQRT_PRICE_MINUS_1
        );
        (bool ok, bytes memory err) = POOL_MANAGER.call(abi.encodeCall(IPoolManager.unlock, (abi.encode(key, sp))));
        require(!ok && err.length >= 4, "the probe never settles, so its unlock cannot succeed");
        bytes4 selector;
        assembly ("memory-safe") {
            selector := and(mload(add(err, 32)), shl(224, 0xffffffff))
        }
        if (selector == TakeSucceeded.selector) {
            assembly ("memory-safe") {
                delta := mload(add(err, 36))
            }
            return (true, delta);
        }
        // Attribute the failure: the manager's call to the hook's afterSwap failed inside a token transfer (the take).
        require(
            _contains(err, abi.encodePacked(SurplusFeeHook.afterSwap.selector))
                && _contains(err, abi.encodePacked(HOOK_CALL_FAILED))
                && _contains(err, abi.encodePacked(ERC20_TRANSFER_FAILED)),
            "the exact-output swap failed for another reason than the hook's take"
        );
        return (false, 0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == POOL_MANAGER, "only the PoolManager");
        (PoolKey memory k, SwapParams memory sp) = abi.decode(data, (PoolKey, SwapParams));
        revert TakeSucceeded(IPoolManager(POOL_MANAGER).swap(k, sp, bytes("")));
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length > haystack.length) return false;
        for (uint256 i; i + needle.length <= haystack.length; ++i) {
            bool found = true;
            for (uint256 j; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
}
