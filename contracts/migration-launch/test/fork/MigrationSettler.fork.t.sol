// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MigrationSettler} from "../../src/MigrationSettler.sol";
import {IPoolManager} from "../../src/LaunchInterfaces.sol";
import {LaunchMath} from "../../src/LaunchMath.sol";
import {LaunchForkBase} from "./LaunchForkBase.sol";
import {HookDouble} from "../utils/HookDouble.sol";

/// @dev The launch settlement on the pinned Base fork, driven through the real Safe batch.
contract MigrationSettlerForkTest is LaunchForkBase {
    function test_Launch_V2SortsAboveWeth() public {
        _launchEndToEnd(false);
    }

    function test_Launch_V2SortsBelowWeth() public {
        _launchEndToEnd(true);
    }

    /// @dev §3.4: only the Safe can call `settle`; the swap callbacks accept only their venue.
    function test_OnlyTheSafeCanSettle() public {
        _launchSetup(false, true);
        MigrationSettler.Params memory p = _params();
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(MigrationSettler.NotSafe.selector, OUTSIDER));
        settler.settle(p);

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(MigrationSettler.NotPoolManager.selector, OUTSIDER));
        settler.unlockCallback("");

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(MigrationSettler.NotTailPool.selector, OUTSIDER));
        settler.uniswapV3SwapCallback(0, 1, "");
    }

    /// @dev §3.4 / RUNBOOK abort path: someone initializes the successor key first, at their own price. Even
    ///      with a hook that does NOT gate initialization, the settler's direct `initialize` reverts
    ///      PoolAlreadyInitialized, so the whole Safe batch reverts and nothing is sold, minted or activated.
    ///      (PositionManager.initializePool would have swallowed this and seeded at the attacker's price.)
    function test_FrontRunInitRevertsTheWholeBatch() public {
        _launchSetup(false, false);
        (MigrationSettler.Params memory p, uint256 v2Budget,,) = _signed();
        vm.prank(OUTSIDER);
        IPoolManager(POOL_MANAGER).initialize(p.newKey, LaunchMath.sqrtPriceAtTick(p.openTick) / 31);

        _expectBatchReverts(p, v2Budget);

        _stepsAsSafe(v2Budget);
        bytes memory err = _settleAsSafe(p);
        assertEq(keccak256(err), keccak256(abi.encodeWithSignature("PoolAlreadyInitialized()")), "revert reason");
    }

    /// @dev With the gated hook the front-run cannot even start: the successor hook's beforeInitialize admits
    ///      only the settler, so an outsider's initialize reverts (v4 wraps the hook's revert).
    function test_GatedHookRejectsAnOutsiderInitialize() public {
        _launchSetup(false, true);
        MigrationSettler.Params memory p = _params();
        vm.prank(OUTSIDER);
        (bool ok, bytes memory err) = POOL_MANAGER.call(
            abi.encodeCall(IPoolManager.initialize, (p.newKey, LaunchMath.sqrtPriceAtTick(p.openTick)))
        );
        assertTrue(!ok, "an outsider initialized the successor pool");
        assertTrue(
            _contains(err, abi.encodeWithSelector(HookDouble.NotInitializer.selector, OUTSIDER)),
            "the hook's gate did not reject the outsider"
        );
    }

    /// @dev §3.4 minWethOut: a sale one wei below the signed floor reverts the whole batch.
    function test_SaleBelowTheSignedMinimumRevertsTheBatch() public {
        _launchSetup(false, true);
        (MigrationSettler.Params memory p, uint256 v2Budget, uint256 simRaised,) = _signed();
        p.minWethOut = simRaised + 1;

        _expectBatchReverts(p, v2Budget);

        _stepsAsSafe(v2Budget);
        bytes memory err = _settleAsSafe(p);
        assertEq(
            keccak256(err),
            keccak256(abi.encodeWithSelector(MigrationSettler.SaleBelowMinimum.selector, simRaised, simRaised + 1)),
            "revert reason"
        );
    }

    /// @dev §3.4 v2 budget: a budget one wei under what the v2 side needs reverts the whole batch.
    function test_V2BudgetBelowTheSeedRevertsTheBatch() public {
        _launchSetup(false, true);
        (MigrationSettler.Params memory p,,, uint256 simV2) = _signed();

        _expectBatchReverts(p, simV2 - 1);

        _stepsAsSafe(simV2 / 2);
        bytes memory err = _settleAsSafe(p);
        assertTrue(_hasSelector(err, MigrationSettler.V2BudgetExceeded.selector), "revert reason");
    }

    // ---------------------------------------------------------------------------------------------
    // The split seed: a v2 side copying the old pool's ladder, a WETH side, meeting at the opening tick
    // ---------------------------------------------------------------------------------------------

    /// @dev The v2 side holds exactly the v1 the old pool held above its price, range by range, in both orders.
    function test_V2SideCopiesTheOldPoolsV1_V2AboveWeth() public {
        _copiesTheOldPool(false);
    }

    function test_V2SideCopiesTheOldPoolsV1_V2BelowWeth() public {
        _copiesTheOldPool(true);
    }

    /// @dev An opening tick off the successor grid cannot be the seam: no position can start there.
    function test_OpenTickOffTheGridReverts() public {
        MigrationSettler.Params memory p = _readyToSettle(false);
        p.openTick += 1;
        assertEq(
            keccak256(_settleAsSafe(p)),
            keccak256(abi.encodeWithSelector(MigrationSettler.OpenTickOffGrid.selector, p.openTick)),
            "revert reason"
        );
    }

    /// @dev A v2 range reaching across the opening tick would take WETH and leave the v2 side two-sided.
    function test_V2RangeAcrossTheOpenReverts() public {
        MigrationSettler.Params memory p = _readyToSettle(false);
        uint256 last = p.v2Ranges.length - 1; // v2 above WETH: the ranges sit below the open, the last one at it
        p.v2Ranges[last].tickUpper = p.openTick + TICK_SPACING;
        assertEq(
            keccak256(_settleAsSafe(p)),
            keccak256(abi.encodeWithSelector(MigrationSettler.BadV2Range.selector, last)),
            "revert reason"
        );
    }

    /// @dev A gap between the v2 side and the opening tick is a hole the first buy would jump across.
    function test_GapAtTheOpenReverts() public {
        MigrationSettler.Params memory p = _readyToSettle(false);
        p.v2Ranges[p.v2Ranges.length - 1].tickUpper = p.openTick - TICK_SPACING;
        assertEq(
            keccak256(_settleAsSafe(p)),
            keccak256(abi.encodeWithSelector(MigrationSettler.V2SideMissesOpen.selector)),
            "revert reason"
        );
    }

    /// @dev A launch with no v2 side would open a pool where buyers find nothing.
    function test_NoV2SideReverts() public {
        MigrationSettler.Params memory p = _readyToSettle(true);
        p.v2Ranges = new MigrationSettler.V2Range[](0);
        assertEq(
            keccak256(_settleAsSafe(p)),
            keccak256(abi.encodeWithSelector(MigrationSettler.V2SideMissesOpen.selector)),
            "revert reason"
        );
    }

    function _copiesTheOldPool(bool v2BelowWeth) internal {
        _launchSetup(v2BelowWeth, true);
        uint256 v1Above = _v1AboveOldPrice();
        (MigrationSettler.Params memory p, uint256 v2Budget,,) = _signed();
        (bool ok, bytes memory ret) = _launch(p, v2Budget);
        require(ok && abi.decode(ret, (bool)), "launch batch");
        uint256 seeded = settler.v2Seeded();
        // Each range's liquidity is the largest that its block's v1 pays for, so a range can fall short of its block
        // by at most what one more unit of liquidity would hold; the PoolManager then rounds the amount up.
        uint256 slack;
        for (uint256 i; i < p.v2Ranges.length; ++i) {
            slack += _v2ForLiquidity(1, p.v2Ranges[i].tickLower, p.v2Ranges[i].tickUpper, v2BelowWeth) + 1;
        }
        emit log_named_uint("old_pool_v1_above_price", v1Above);
        emit log_named_uint("successor_v2_side", seeded);
        emit log_named_uint("copy_shortfall_wei", v1Above - seeded);
        emit log_named_uint("copy_slack_wei", slack);
        emit log_named_uint("v2_ranges", p.v2Ranges.length);
        assertTrue(seeded <= v1Above && v1Above - seeded <= slack, "v2 side != the old pool's v1");
        assertEq(IERC20(address(v2)).balanceOf(POOL_MANAGER), seeded, "the PoolManager holds the v2 side");
    }

    /// @dev v4 SqrtPriceMath amounts, rounded up: v2 as currency0 above the price, as currency1 below it.
    function _v2ForLiquidity(uint128 liq, int24 lower, int24 upper, bool v2Is0) internal pure returns (uint256) {
        uint256 a = LaunchMath.sqrtPriceAtTick(lower);
        uint256 b = LaunchMath.sqrtPriceAtTick(upper);
        return v2Is0
            ? Math.ceilDiv(Math.mulDiv(uint256(liq) << 96, b - a, b, Math.Rounding.Up), a)
            : Math.mulDiv(liq, b - a, 1 << 96, Math.Rounding.Up);
    }

    /// @dev The launch batch up to `settle`, so each case reaches the settler with real balances; the signed params
    ///      themselves settle (the control).
    function _readyToSettle(bool v2BelowWeth) internal returns (MigrationSettler.Params memory p) {
        _launchSetup(v2BelowWeth, true);
        uint256 v2Budget;
        (p, v2Budget,,) = _signed();
        _stepsAsSafe(v2Budget);
        uint256 snapshot = vm.snapshotState();
        vm.prank(address(safe));
        settler.settle(p);
        assertTrue(settler.v2Seeded() != 0 && settler.wethSeeded() != 0, "control: the signed params launch");
        require(vm.revertToState(snapshot), "restore");
    }

    function _launchEndToEnd(bool v2BelowWeth) internal {
        _launchSetup(v2BelowWeth, true);
        (MigrationSettler.Params memory p, uint256 v2Budget, uint256 simRaised,) = _signed();
        uint256 nonceBefore = safe.nonce();
        (bool ok, bytes memory ret) = _launch(p, v2Budget);
        require(ok && abi.decode(ret, (bool)) && safe.nonce() == nonceBefore + 1, "launch batch");
        _assertLaunched(p, v2Budget, simRaised);
    }

    function _hasSelector(bytes memory err, bytes4 selector) internal pure returns (bool) {
        if (err.length < 4) return false;
        return err[0] == selector[0] && err[1] == selector[1] && err[2] == selector[2] && err[3] == selector[3];
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
