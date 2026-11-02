// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SurplusPoolHook} from "@surplus/pool-hook/src/SurplusPoolHook.sol";
import {MigrationSettler} from "../../src/MigrationSettler.sol";
import {IPoolManager, IPositionManager, IUnlockCallback, PoolKey, SwapParams} from "../../src/LaunchInterfaces.sol";
import {LaunchMath} from "../../src/LaunchMath.sol";
import {LaunchForkBase} from "./LaunchForkBase.sol";

/**
 * @dev The launch with the REAL successor hook (contracts/pool-hook), deployed as production will: CREATE2
 *      through the canonical deployer at the smallest salt whose address carries exactly the 0x2000 flag,
 *      initializer = the settler. The Safe batch launches through it and an outsider cannot initialize the
 *      official key first. Live trades in both directions, exact-in and exact-out, pay the pool's 1.2% LP fee and
 *      nothing to the hook, and the Safe, which owns every launch position, collects that fee.
 */
contract RealHookLaunchForkTest is LaunchForkBase, IUnlockCallback {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant TRADER = address(0x7EAD7);
    uint160 internal constant MIN_SQRT_PRICE_PLUS_1 = 4_295_128_740;
    uint160 internal constant MAX_SQRT_PRICE_MINUS_1 = 1461446703485210103287273052203988822378723970341;
    uint256 internal constant PIPS = 1_000_000;
    /// @dev v4-periphery Actions.
    bytes1 internal constant DECREASE_LIQUIDITY = 0x01;
    bytes1 internal constant TAKE_PAIR = 0x11;

    SurplusPoolHook internal hook;
    uint256 internal wethPaid;
    uint256 internal v2Paid;

    function test_LaunchAndTradeThroughTheRealHook() public {
        _launchSetup(false, true);
        hook = _deployRealHook();
        successorHook = address(hook);
        (MigrationSettler.Params memory p, uint256 v2Budget,,) = _signed();
        assertEq(p.newKey.hooks, address(hook), "the signed key names the real hook");

        // Once the hook exists its key is public: an outsider still cannot open the pool first.
        uint160 openPrice = LaunchMath.sqrtPriceAtTick(p.openTick);
        vm.prank(OUTSIDER);
        (bool frontRun,) = POOL_MANAGER.call(abi.encodeCall(IPoolManager.initialize, (p.newKey, openPrice)));
        assertTrue(!frontRun, "an outsider initialized the official key");

        (bool ok, bytes memory ret) = _launch(p, v2Budget);
        require(ok && abi.decode(ret, (bool)), "launch batch through the real hook");
        (uint160 sqrtPriceX96, uint24 lpFee, uint128 liq) = _poolState(keccak256(abi.encode(p.newKey)));
        assertEq(sqrtPriceX96, openPrice, "opened at the signed tick's price");
        assertEq(lpFee, 12_000, "the pool charges the decided 1.2% LP fee");
        // v2 above WETH: WETH is currency0, so the WETH side is the position active at the open.
        assertEq(liq, settler.wethLiquidity(), "seeded");

        _trade(p.newKey, true, -int256(0.5 ether), "exact-in buy of v2 with WETH");
        _trade(p.newKey, false, -int256(1_000_000 ether), "exact-in sell of v2 for WETH");
        _trade(p.newKey, true, int256(1_000_000 ether), "exact-out buy of v2 with WETH");
        _trade(p.newKey, false, int256(0.1 ether), "exact-out sell of v2 for WETH");
        _safeCollectsTheLpFee(p.newKey);
    }

    /// @dev Same derivation as kit/deploy_plan.py: smallest salt from 0 whose CREATE2 address has exactly the flags.
    function _deployRealHook() internal returns (SurplusPoolHook deployed) {
        (address c0, address c1) = address(v2) < WETH ? (address(v2), WETH) : (WETH, address(v2));
        bytes memory init = abi.encodePacked(
            type(SurplusPoolHook).creationCode, abi.encode(POOL_MANAGER, address(settler), c0, c1, LP_FEE, TICK_SPACING)
        );
        bytes32 initHash = keccak256(init);
        for (uint256 s;; ++s) {
            bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, bytes32(s), initHash));
            // forge-lint: disable-next-line(unsafe-typecast)
            address candidate = address(uint160(uint256(h)));
            if ((uint160(candidate) & ((1 << 14) - 1)) != 0x2000) continue;
            (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(bytes32(s), init));
            require(ok && ret.length == 20 && candidate.code.length != 0, "CREATE2 deploy");
            deployed = SurplusPoolHook(candidate);
            break;
        }
        require(
            deployed.INITIALIZER() == address(settler) && deployed.LP_FEE() == LP_FEE
                && deployed.TICK_SPACING() == TICK_SPACING,
            "hook config"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Trades: a minimal v4 router (this contract is the unlock callback)
    // ---------------------------------------------------------------------------------------------

    struct Trade {
        PoolKey key;
        SwapParams params;
    }

    /// @dev `buyV2` swaps WETH for v2. A negative amount is exact-in, positive is exact-out (v4 convention). Records
    ///      what the trader paid in each currency and checks that the hook took nothing.
    function _trade(PoolKey memory key, bool buyV2, int256 amount, string memory label) internal {
        bool wethIs0 = key.currency0 == WETH;
        bool zeroForOne = buyV2 == wethIs0; // selling currency0 for currency1
        SwapParams memory sp =
            SwapParams(zeroForOne, amount, zeroForOne ? MIN_SQRT_PRICE_PLUS_1 : MAX_SQRT_PRICE_MINUS_1);
        int256 delta = abi.decode(IPoolManager(POOL_MANAGER).unlock(abi.encode(Trade(key, sp))), (int256));
        int128 paid = zeroForOne ? LaunchMath.amount0(delta) : LaunchMath.amount1(delta);
        assertTrue(paid < 0, string.concat(label, ": the trader paid nothing in"));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 input = uint256(uint128(-paid));
        if (buyV2) wethPaid += input;
        else v2Paid += input;
        _assertHookHoldsNothing(label);
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
            _fund(currency, owed);
            IPoolManager(POOL_MANAGER).sync(currency);
            require(IERC20(currency).transfer(POOL_MANAGER, owed), "pay the manager");
            IPoolManager(POOL_MANAGER).settle();
        } else if (amount > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            IPoolManager(POOL_MANAGER).take(currency, TRADER, uint256(uint128(amount)));
        }
    }

    /// @dev WETH comes from wrapping test ETH; v2 is minted by the Safe (it holds MINTER_ROLE).
    function _fund(address currency, uint256 amount) internal {
        if (currency == WETH) {
            vm.deal(address(this), amount);
            (bool ok,) = WETH.call{value: amount}(abi.encodeWithSignature("deposit()"));
            require(ok, "wrap");
        } else {
            vm.prank(address(safe));
            v2.mint(address(this), amount);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // The LP fee: one Safe transaction collects it from every launch position
    // ---------------------------------------------------------------------------------------------

    /// @dev DECREASE_LIQUIDITY by 0 on each LP NFT credits its fees, and TAKE_PAIR sends them to the Safe. The
    ///      fee is 1.2% of every trade's input, exact-in or exact-out, in the input currency, and every in-range
    ///      position is the Safe's, so the Safe collects 1.2% of what the trades paid in, less floor rounding.
    function _safeCollectsTheLpFee(PoolKey memory key) internal {
        uint256 first = settler.firstPositionId();
        uint256 n = settler.positionCount();
        bytes memory actions = new bytes(n + 1);
        bytes[] memory params = new bytes[](n + 1);
        for (uint256 i; i < n; ++i) {
            actions[i] = DECREASE_LIQUIDITY;
            params[i] = abi.encode(first + i, uint256(0), uint128(0), uint128(0), bytes(""));
        }
        actions[n] = TAKE_PAIR;
        params[n] = abi.encode(key.currency0, key.currency1, address(safe));
        uint256 wethBefore = IERC20(WETH).balanceOf(address(safe));
        uint256 v2Before = v2.balanceOf(address(safe));
        _safeExec(
            POSITION_MANAGER,
            abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), block.timestamp))
        );
        _checkFee("WETH", IERC20(WETH).balanceOf(address(safe)) - wethBefore, wethPaid);
        _checkFee("v2", v2.balanceOf(address(safe)) - v2Before, v2Paid);
        _assertHookHoldsNothing("after the fee collection");
    }

    function _checkFee(string memory label, uint256 collected, uint256 paidIn) internal {
        uint256 sharePips = collected * PIPS / paidIn;
        emit log_named_uint(string.concat(label, " LP fee collected by the Safe (wei)"), collected);
        emit log_named_uint(string.concat(label, " LP fee, millionths of the trades' input"), sharePips);
        assertTrue(sharePips == 12_000 || sharePips == 11_999, string.concat(label, ": the Safe did not collect 1.2%"));
    }

    function _assertHookHoldsNothing(string memory label) internal view {
        assertTrue(
            IERC20(WETH).balanceOf(address(hook)) == 0 && v2.balanceOf(address(hook)) == 0,
            string.concat(label, ": the hook holds tokens")
        );
    }
}
