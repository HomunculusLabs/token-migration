// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MigrationSettler} from "../../src/MigrationSettler.sol";
import {IPermit2, IPoolManager, IPositionManager, PoolKey} from "../../src/LaunchInterfaces.sol";
import {LaunchForkBase} from "./LaunchForkBase.sol";
import {HookDouble} from "../utils/HookDouble.sol";

interface IWETH9 {
    function deposit() external payable;
}

/**
 * @dev Regressions for the defects found while porting the rehearsal settler (§3.4). Each test fails on
 *      the code before its fix and passes after it.
 */
contract SettlerRegressionsForkTest is LaunchForkBase {
    /// @dev A v1 holder outside the cohort. It never deposits, so its v1 is free to donate.
    address internal constant V1_DONOR = 0xb06b821eBDE1Ae3db7C38757aaD75CDc1252290b;

    /// @dev S1: the launch must leave the settler holding no token and no approval. The rehearsal settler left
    ///      unlimited WETH and v2 approvals behind (ERC20 → Permit2 at max, Permit2 → PositionManager at max
    ///      amount and max expiry). The settler never approves v1, and v1's own Permit2 allowance is infinite
    ///      for every address by the v1 token's design, so v1 is compared with that default.
    function test_S1_LaunchLeavesNoTokensOrApprovals() public {
        _launchSetup(false, true);
        (MigrationSettler.Params memory p, uint256 v2Budget,,) = _signed();
        (bool ok, bytes memory ret) = _launch(p, v2Budget);
        require(ok && abi.decode(ret, (bool)), "launch batch");

        _assertNothingLeft(WETH, "WETH");
        _assertNothingLeft(address(v2), "v2");
        _assertNothingLeft(V1, "v1");
    }

    /// @dev S2: anyone can send v1 or WETH to the settler's public address between signing and execution. The
    ///      rehearsal settler sold every v1 it held and seeded every WETH it held, so a donation of just over
    ///      0.1% of the sale pushed the seed past the signed v2 budget and reverted the launch: a cheap and
    ///      repeatable grief. The launch must sell and seed exactly what was signed, and return any donation to
    ///      the Safe.
    function test_S2_DonationCannotBlockTheLaunch() public {
        _launchSetup(false, true);
        (MigrationSettler.Params memory p, uint256 v2Budget, uint256 simRaised, uint256 simV2) = _signed();

        uint256 wethDonation = simRaised / 100;
        vm.deal(OUTSIDER, wethDonation);
        vm.startPrank(OUTSIDER);
        IWETH9(WETH).deposit{value: wethDonation}();
        require(IERC20(WETH).transfer(address(settler), wethDonation), "WETH donation");
        vm.stopPrank();
        uint256 v1Donation = total / 100;
        vm.prank(V1_DONOR);
        require(IERC20(V1).transfer(address(settler), v1Donation), "v1 donation");

        (bool ok, bytes memory ret) = _launch(p, v2Budget);
        assertTrue(ok && abi.decode(ret, (bool)), "a donation blocked the launch");
        assertEq(settler.wethRaised(), simRaised, "the sale is exactly the signed one");
        assertEq(settler.v2Seeded(), simV2, "the seed is exactly the signed one");
        assertEq(IERC20(V1).balanceOf(address(safe)), v1Donation, "the v1 donation is returned to the Safe");
        assertEq(
            IERC20(WETH).balanceOf(address(safe)),
            simRaised - settler.wethSeeded() + wethDonation,
            "the WETH donation is returned to the Safe"
        );
        _assertNothingLeft(V1, "v1");
        _assertNothingLeft(WETH, "WETH");
    }

    /// @dev S3: a mistake in the signed successor key must revert the launch, never open and seed the wrong
    ///      pool. The rehearsal settler initialized whatever key Params named. With no hook, or with a hook that
    ///      is not bound to the settler, the batch "succeeded" and put all the liquidity in a pool that never
    ///      charges the 1.5% fee. With the wrong fee or spacing it opened a pool that nothing routes to. The
    ///      selectors are spelled out so this file compiles against the settler before the fix.
    bytes4 internal constant WRONG_SUCCESSOR_KEY = bytes4(keccak256("WrongSuccessorKey()"));
    bytes4 internal constant WRONG_HOOK = bytes4(keccak256("WrongHook(address)"));

    function test_S3_NoSuccessorHookReverts() public {
        MigrationSettler.Params memory p = _readyToSettle();
        p.newKey.hooks = address(0);
        _expectSettleReverts(p, abi.encodeWithSelector(WRONG_HOOK, address(0)), "no successor hook");
    }

    function test_S3_HookNotBoundToTheSettlerReverts() public {
        MigrationSettler.Params memory p = _readyToSettle();
        // The right permission bits, but an ungated hook whose initializer is someone else.
        address decoy = address((uint160(0xDEC0) << 136) | 0x2044);
        vm.etch(decoy, address(new HookDouble(OUTSIDER, OUTSIDER, false)).code);
        p.newKey.hooks = decoy;
        _expectSettleReverts(p, abi.encodeWithSelector(WRONG_HOOK, decoy), "a hook not bound to the settler");
    }

    function test_S3_WrongSuccessorFeeReverts() public {
        MigrationSettler.Params memory p = _readyToSettle();
        p.newKey.fee = 10_000; // 1% instead of the decided 0.30%
        _expectSettleReverts(p, abi.encodeWithSelector(WRONG_SUCCESSOR_KEY), "wrong successor fee");
    }

    function test_S3_WrongSuccessorTickSpacingReverts() public {
        MigrationSettler.Params memory p = _readyToSettle();
        p.newKey.tickSpacing = 20; // still divides the full-range ticks, so only the key check can catch it
        _expectSettleReverts(p, abi.encodeWithSelector(WRONG_SUCCESSOR_KEY), "wrong successor tick spacing");
    }

    /// @dev S4: a mis-built old key must not become a sale venue. The rehearsal settler sold into ANY v1/WETH
    ///      v4 pool the params named. Anyone can open one with dust liquidity, and the simulation behind
    ///      `minWethOut` would run on the same wrong key, so the floor would not stop it: the whole migrated v1
    ///      would sell for almost nothing. The settler must sell only on the pinned Doppler pool.
    bytes4 internal constant WRONG_OLD_POOL = bytes4(keccak256("WrongOldPool(bytes32)"));

    function test_S4_RivalOldPoolIsNotAVenue() public {
        MigrationSettler.Params memory p = _readyToSettle();
        PoolKey memory rival = PoolKey(WETH, V1, 3000, 60, address(0));
        _openDustPool(rival, _sqrtPrice(OLD_POOL_ID));
        p.oldKey = rival;
        p.minWethOut = 0; // the simulation of a mis-keyed batch would have signed ~0 as the floor
        _expectSettleReverts(
            p, abi.encodeWithSelector(WRONG_OLD_POOL, keccak256(abi.encode(rival))), "a rival old pool"
        );
    }

    /// @dev Anyone can open a hookless v1/WETH pool and add full-range liquidity worth a fraction of a cent.
    function _openDustPool(PoolKey memory key, uint160 sqrtPriceX96) internal {
        vm.deal(OUTSIDER, 1 ether);
        vm.prank(V1_DONOR);
        require(IERC20(V1).transfer(OUTSIDER, 1 ether), "v1 for the dust pool");
        vm.startPrank(OUTSIDER);
        IWETH9(WETH).deposit{value: 1 ether}();
        IPoolManager(POOL_MANAGER).initialize(key, sqrtPriceX96);
        require(IERC20(WETH).approve(PERMIT2, type(uint256).max), "approve");
        IPermit2(PERMIT2).approve(WETH, POSITION_MANAGER, type(uint160).max, type(uint48).max);
        IPermit2(PERMIT2).approve(V1, POSITION_MANAGER, type(uint160).max, type(uint48).max);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, int24(-887_220), int24(887_220), uint256(1e12), uint128(1 ether), uint128(1 ether), OUTSIDER, ""
        );
        params[1] = abi.encode(WETH, V1);
        IPositionManager(POSITION_MANAGER).modifyLiquidities(abi.encode(hex"020d", params), block.timestamp);
        vm.stopPrank();
    }

    /// @dev The launch batch up to `settle`, so each case reaches the settler with real balances; the signed
    ///      params themselves settle (the control).
    function _readyToSettle() internal returns (MigrationSettler.Params memory p) {
        _launchSetup(false, true);
        uint256 v2Budget;
        (p, v2Budget,,) = _signed();
        _stepsAsSafe(v2Budget);
        uint256 snapshot = vm.snapshotState();
        vm.prank(address(safe));
        settler.settle(p);
        assertTrue(settler.v2Seeded() != 0, "control: the signed params launch");
        require(vm.revertToState(snapshot), "restore");
    }

    function _expectSettleReverts(MigrationSettler.Params memory p, bytes memory expected, string memory label)
        internal
    {
        vm.prank(address(safe));
        (bool ok, bytes memory ret) = address(settler).call(abi.encodeCall(MigrationSettler.settle, (p)));
        assertTrue(!ok, string.concat("settle accepted: ", label));
        assertEq(keccak256(ret), keccak256(expected), string.concat("revert reason: ", label));
    }

    function _assertNothingLeft(address token, string memory label) internal view {
        IERC20 t = IERC20(token);
        assertEq(t.balanceOf(address(settler)), 0, string.concat(label, ": balance left in the settler"));
        assertEq(
            t.allowance(address(settler), PERMIT2),
            t.allowance(OUTSIDER, PERMIT2),
            string.concat(label, ": ERC20 allowance to Permit2 left behind")
        );
        (uint160 amount,,) = IPermit2(PERMIT2).allowance(address(settler), token, POSITION_MANAGER);
        assertEq(amount, 0, string.concat(label, ": Permit2 allowance to the PositionManager left behind"));
    }
}
