// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SurplusFeeHook} from "@surplus/fee-hook/src/SurplusFeeHook.sol";
import {MigrationSettler} from "../../src/MigrationSettler.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "../../src/LaunchInterfaces.sol";
import {LaunchMath} from "../../src/LaunchMath.sol";
import {LaunchForkBase} from "./LaunchForkBase.sol";

/**
 * @dev The launch with the REAL successor hook (contracts/fee-hook), deployed as production will: CREATE2
 *      through the canonical deployer at the smallest salt whose address carries exactly the 0x2044 flags,
 *      initializer = the settler. The Safe batch launches through it, an outsider cannot initialize the
 *      official key first, and live trades in both directions, exact-in and exact-out, pay the hook 1.5% of
 *      the unspecified side. The Safe then withdraws both halves.
 */
contract RealHookLaunchForkTest is LaunchForkBase, IUnlockCallback {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant TRADER = address(0x7EAD7);
    uint160 internal constant MIN_SQRT_PRICE_PLUS_1 = 4_295_128_740;
    uint160 internal constant MAX_SQRT_PRICE_MINUS_1 = 1461446703485210103287273052203988822378723970341;

    SurplusFeeHook internal hook;

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
        (uint160 sqrtPriceX96,, uint128 liq) = _poolState(keccak256(abi.encode(p.newKey)));
        assertEq(sqrtPriceX96, openPrice, "opened at the signed tick's price");
        // v2 above WETH: WETH is currency0, so the WETH side is the position active at the open.
        assertEq(liq, settler.wethLiquidity(), "seeded");

        _tradeAndCheckFee(p.newKey, true, -int256(0.5 ether), "exact-in buy of v2 with WETH");
        _tradeAndCheckFee(p.newKey, false, -int256(1_000_000 ether), "exact-in sell of v2 for WETH");
        _tradeAndCheckFee(p.newKey, true, int256(1_000_000 ether), "exact-out buy of v2 with WETH");
        _tradeAndCheckFee(p.newKey, false, int256(0.1 ether), "exact-out sell of v2 for WETH");
        _safeWithdrawsFees();
    }

    /// @dev Same derivation as kit/deploy_plan.py: smallest salt from 0 whose CREATE2 address has exactly the flags.
    function _deployRealHook() internal returns (SurplusFeeHook deployed) {
        (address c0, address c1) = address(v2) < WETH ? (address(v2), WETH) : (WETH, address(v2));
        bytes memory init = abi.encodePacked(
            type(SurplusFeeHook).creationCode,
            abi.encode(POOL_MANAGER, address(safe), address(settler), c0, c1, LP_FEE, TICK_SPACING)
        );
        bytes32 initHash = keccak256(init);
        for (uint256 s;; ++s) {
            bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, bytes32(s), initHash));
            // forge-lint: disable-next-line(unsafe-typecast)
            address candidate = address(uint160(uint256(h)));
            if ((uint160(candidate) & ((1 << 14) - 1)) != 0x2044) continue;
            (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(bytes32(s), init));
            require(ok && ret.length == 20 && candidate.code.length != 0, "CREATE2 deploy");
            deployed = SurplusFeeHook(candidate);
            break;
        }
        require(
            deployed.INITIALIZER() == address(settler) && deployed.TREASURY() == address(safe)
                && deployed.LP_FEE() == LP_FEE && deployed.TICK_SPACING() == TICK_SPACING,
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

    /// @dev `buyV2` swaps WETH for v2. A negative amount is exact-in, positive is exact-out (v4 convention).
    function _tradeAndCheckFee(PoolKey memory key, bool buyV2, int256 amount, string memory label) internal {
        bool wethIs0 = key.currency0 == WETH;
        bool zeroForOne = buyV2 == wethIs0; // selling currency0 for currency1
        SwapParams memory sp =
            SwapParams(zeroForOne, amount, zeroForOne ? MIN_SQRT_PRICE_PLUS_1 : MAX_SQRT_PRICE_MINUS_1);
        bool exactIn = amount < 0;
        // The hook charges the UNSPECIFIED currency: the output of exact-in, the input of exact-out.
        address feeCurrency = exactIn == zeroForOne ? key.currency1 : key.currency0;
        uint256 takenBefore = hook.totalTaken(feeCurrency);

        int256 delta = abi.decode(IPoolManager(POOL_MANAGER).unlock(abi.encode(Trade(key, sp))), (int256));
        int128 unspecified = feeCurrency == key.currency0 ? LaunchMath.amount0(delta) : LaunchMath.amount1(delta);
        // The trader's delta on the unspecified side already includes the fee: output reduced by it (exact-in),
        // input increased by it (exact-out). Recover the pool's own amount and check the take is 1.5% of it.
        uint256 taken = hook.totalTaken(feeCurrency) - takenBefore;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 traderSide = uint256(uint128(unspecified < 0 ? -unspecified : unspecified));
        uint256 poolSide = exactIn ? traderSide + taken : traderSide - taken;
        assertEq(taken, (poolSide * 15_000) / 1_000_000, string.concat(label, ": hook took exactly 1.5%"));
        assertTrue(taken != 0, string.concat(label, ": fee was charged"));
        emit log_named_uint(string.concat(label, " fee (wei)"), taken);
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

    function _safeWithdrawsFees() internal {
        address[2] memory currencies = [WETH, address(v2)];
        for (uint256 i; i < 2; ++i) {
            address c = currencies[i];
            uint256 team = hook.teamOwed(c);
            uint256 buyback = hook.buybackOwed(c);
            assertTrue(team != 0 && buyback != 0, "both halves accrued");
            uint256 before = IERC20(c).balanceOf(address(safe));
            _safeExec(address(hook), abi.encodeCall(SurplusFeeHook.withdrawTeam, (c, address(safe), team)));
            _safeExec(address(hook), abi.encodeCall(SurplusFeeHook.withdrawBuyback, (c, address(safe), buyback)));
            assertEq(IERC20(c).balanceOf(address(safe)) - before, team + buyback, "the Safe received both halves");
            assertEq(IERC20(c).balanceOf(address(hook)), 0, "no fee left in the hook");
        }
    }
}
