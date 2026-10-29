// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MigrationSettler} from "../../src/MigrationSettler.sol";
import {IPoolManager, PoolKey, SwapParams} from "../../src/LaunchInterfaces.sol";
import {LaunchMath} from "../../src/LaunchMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LaunchForkBase} from "./LaunchForkBase.sol";

interface IWETH9 {
    function deposit() external payable;
    function balanceOf(address) external view returns (uint256);
}

/// @dev A searcher: trades the old (Doppler v4) pool through the PoolManager like any v4 router,
///      settling each leg from its own inventory. Legs are separate transactions in production;
///      in the test each leg is one external call, sequenced around the Safe batch.
contract MevAttacker {
    uint160 internal constant MAX_SQRT_PRICE_MINUS_1 = 1461446703485210103287273052203988822378723970341;
    uint160 internal constant MIN_SQRT_PRICE_PLUS_1 = 4_295_128_740;

    address internal immutable POOL_MANAGER;
    address internal immutable WETH9;

    constructor(address pm) payable {
        POOL_MANAGER = pm;
        WETH9 = 0x4200000000000000000000000000000000000006;
    }

    function sellV1(PoolKey calldata key, uint256 v1Amount) external {
        IPoolManager(POOL_MANAGER)
            .unlock(
                abi.encode(
                    key,
                    // forge-lint: disable-next-line(unsafe-typecast)
                    SwapParams(false, -int256(v1Amount), MAX_SQRT_PRICE_MINUS_1),
                    uint8(0)
                )
            );
    }

    function buyV1ExactOut(PoolKey calldata key, uint256 v1Out) external {
        IPoolManager(POOL_MANAGER)
            .unlock(
                abi.encode(
                    key,
                    // forge-lint: disable-next-line(unsafe-typecast)
                    SwapParams(true, int256(v1Out), MIN_SQRT_PRICE_PLUS_1),
                    uint8(1)
                )
            );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == POOL_MANAGER, "only PoolManager");
        (PoolKey memory key, SwapParams memory sp,) = abi.decode(data, (PoolKey, SwapParams, uint8));
        int256 delta = IPoolManager(POOL_MANAGER).swap(key, sp, bytes(""));
        _settleSide(key.currency0, LaunchMath.amount0(delta), WETH9);
        _settleSide(key.currency1, LaunchMath.amount1(delta), WETH9);
        return bytes("");
    }

    /// @dev Owing v1: pay from held inventory. Owing WETH: wrap fresh ETH (exact-in buys).
    ///      Receiving anything: take() it. The attacker holds v1 inventory and funded ETH only.
    function _settleSide(address currency, int128 amount, address weth) internal {
        if (amount < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 owed = uint256(uint128(-amount));
            if (currency == weth) IWETH9(weth).deposit{value: owed}();
            IPoolManager(POOL_MANAGER).sync(currency);
            require(IERC20(currency).transfer(POOL_MANAGER, owed), "pay");
            IPoolManager(POOL_MANAGER).settle();
        } else if (amount > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            IPoolManager(POOL_MANAGER).take(currency, address(this), uint256(uint128(amount)));
        }
    }
}

/**
 * @title MEV red-team against the atomic launch batch (pinned Base fork).
 * @dev Real-searcher attack bundles sequenced around the REAL Safe batch, with the REAL signed
 *      floor from `_signed()` (0.5% under simulation). The existing suites prove the guards fire
 *      (front-run init -> GS013; one-wei-below floor -> SaleBelowMinimum; donation -> returned);
 *      these tests prove what a profit-seeking adversary WALKS AWAY WITH in each strategy, which
 *      is the actual MEV question. Attacker inventory: 1M v1 from a non-cohort whale plus 200
 *      wrapped ETH, capital on the order of the launch's own tail leg. Deliberately generous.
 */
contract MevRedTeamForkTest is LaunchForkBase {
    /// @dev A v1 whale OUTSIDE the cohort (never deposited, free to trade): the searcher's inventory.
    address internal constant SEARCHER_V1_WHALE = 0xb06b821eBDE1Ae3db7C38757aaD75CDc1252290b;

    uint256 internal constant SEARCHER_V1 = 1_000_000 ether;
    uint256 internal constant SEARCHER_ETH = 200 ether;
    /// @dev The grief leg uses HALF the whale's real 918M v1: a vandal with ~10% of the launch's
    ///      own 4.86B v1 sale size. 1M v1 proved too small to matter (M1's dump moved proceeds 0.019%).
    uint256 internal constant GRIEF_V1 = 460_000_000 ether;

    constructor() payable {}

    // ---------------------------------------------------------------------------------------------
    // M1 - the classic sandwich: front-sell v1 (depress the pool), launch sells into the hole,
    // backrun-buy the cheap v1. The only strategy that could extract value FROM the launch.
    // ---------------------------------------------------------------------------------------------
    function test_M1_SandwichFrontSellLaunchBackrun() public {
        _launchSetup(false, true);
        (MigrationSettler.Params memory p, uint256 v2Budget, uint256 simRaised,) = _signed();

        MevAttacker attacker = _armedAttacker();
        uint256 weth0 = IWETH9(WETH).balanceOf(address(attacker));
        uint256 eth0 = address(attacker).balance; // buyback legs wrap FRESH native: PnL must span both

        // LEG 1 - front-run: dump 1M v1 ahead of the launch.
        attacker.sellV1(p.oldKey, SEARCHER_V1);

        // LEG 2 - the signed launch batch executes against the moved pool.
        uint256 nonceBefore = safe.nonce();
        (bool ok,) = _launch(p, v2Budget);
        if (!ok) {
            // The floor tripped: nothing sold. The searcher unwinds into their own impact.
            attacker.buyV1ExactOut(p.oldKey, SEARCHER_V1);
            _assertLaunchAbortedClean(nonceBefore);
            _reportRoundTrip("M1", weth0, IWETH9(WETH).balanceOf(address(attacker)), SEARCHER_V1, attacker);
            return;
        }

        // The batch survived the front-run (searcher too small to trip the 0.5% floor).
        // LEG 3 - backrun: buy back all the front-sold v1 at the post-launch price.
        attacker.buyV1ExactOut(p.oldKey, SEARCHER_V1);
        // Round-trip PnL spans WETH AND native, signed: legs that buy pay by wrapping fresh native
        // ETH, and an UNPROFITABLE attack ends below the starting balances — an unsigned delta
        // would revert there instead of measuring the loss.
        int256 profit =
        // forge-lint: disable-next-line(unsafe-typecast)
            int256(IWETH9(WETH).balanceOf(address(attacker)) + address(attacker).balance) - int256(weth0 + eth0);
        uint256 margin = simRaised - p.minWethOut;

        emit log_named_uint("M1: batch EXECUTED; raised (wei WETH)", settler.wethRaised());
        emit log_named_uint("M1: simulated raise (wei WETH)", simRaised);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit log_named_uint(
            "M1: searcher round-trip |delta|, 1=profit 0=loss sign follows (wei WETH+ETH)",
            uint256(profit < 0 ? -profit : profit)
        );
        emit log_named_uint("M1: delta sign (1 = profit, 0 = loss)", profit >= 0 ? 1 : 0);
        emit log_named_uint("M1: signed floor margin (wei WETH)", margin);
        // The designed bound: whatever the searcher extracts, the launch lost at most the floor
        // margin - and the searcher's round trip cannot beat that.
        assertTrue(settler.wethRaised() >= p.minWethOut, "M1: launch executed below its own floor");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertTrue(profit <= int256(margin), "M1: searcher extracted more than the floor margin");
    }

    // ---------------------------------------------------------------------------------------------
    // M2 - price-push: BUY 100k v1 exact-out before the batch (push the price UP), then, if the
    // batch still executes, unwind by selling the pushed tranche after the launch's own sell
    // pushed the price back down. The push can only HELP the launch's WETH proceeds; the open
    // question is whether the round trip is profitable for the searcher at all.
    // ---------------------------------------------------------------------------------------------
    function test_M2_PricePushThenHarvestTheDislocation() public {
        _launchSetup(false, true);
        (MigrationSettler.Params memory p, uint256 v2Budget, uint256 simRaised,) = _signed();

        MevAttacker attacker = _armedAttacker();
        uint256 weth0 = IWETH9(WETH).balanceOf(address(attacker));
        uint256 eth0 = address(attacker).balance; // push legs wrap FRESH native: PnL must span both

        // LEG 1 - push: buy 100k v1 exact-out, hard price impact upward.
        uint256 push = SEARCHER_V1 / 10;
        attacker.buyV1ExactOut(p.oldKey, push);

        // LEG 2 - the batch.
        uint256 nonceBefore = safe.nonce();
        (bool ok,) = _launch(p, v2Budget);
        if (!ok) {
            attacker.sellV1(p.oldKey, push); // unwind the push
            _assertLaunchAbortedClean(nonceBefore);
            _reportRoundTrip("M2", weth0, IWETH9(WETH).balanceOf(address(attacker)), SEARCHER_V1, attacker);
            return;
        }

        // LEG 3 - unwind the pushed tranche at post-launch prices (the launch sold ~90% of the
        // migrated v1 into the pool, pushing the price down past the searcher's entry).
        uint256 v1Held = IERC20(V1).balanceOf(address(attacker)) - SEARCHER_V1;
        assertTrue(v1Held == push, "M2: push leg inventory");
        attacker.sellV1(p.oldKey, v1Held);
        // Same signed span rule as M1: the push leg's cost sits in native ETH, and a losing
        // round trip must measure as a loss, not revert.
        int256 profit =
        // forge-lint: disable-next-line(unsafe-typecast)
            int256(IWETH9(WETH).balanceOf(address(attacker)) + address(attacker).balance) - int256(weth0 + eth0);

        emit log_named_uint("M2: batch EXECUTED; raised (wei WETH)", settler.wethRaised());
        emit log_named_uint("M2: simulated raise (wei WETH)", simRaised);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit log_named_uint("M2: searcher round-trip |delta| (wei WETH+ETH)", uint256(profit < 0 ? -profit : profit));
        emit log_named_uint("M2: delta sign (1 = profit, 0 = loss)", profit >= 0 ? 1 : 0);
        assertTrue(settler.wethRaised() >= p.minWethOut, "M2: launch executed below its own floor");
        assertTrue(
            // forge-lint: disable-next-line(unsafe-typecast)
            profit <= int256(simRaised - p.minWethOut),
            "M2: searcher extracted more than the floor margin from the dislocation"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // M3 - pure grief: front-sell HARD to force the batch below its floor and stall the launch.
    // Profit for the attacker is impossible if the batch aborts (they unwind against their own
    // impact); the test measures exactly what that vandalism costs them.
    // ---------------------------------------------------------------------------------------------
    function test_M3_PureGriefCostsTheSearcherRealCapital() public {
        _launchSetup(false, true);
        (MigrationSettler.Params memory p, uint256 v2Budget, uint256 simRaised,) = _signed();

        MevAttacker attacker = _armedAttacker();
        assertTrue(IERC20(V1).balanceOf(SEARCHER_V1_WHALE) >= GRIEF_V1, "the grief whale cannot fund the dump");
        vm.prank(SEARCHER_V1_WHALE);
        assertTrue(IERC20(V1).transfer(address(attacker), GRIEF_V1 - SEARCHER_V1), "arm the grief tranche");
        uint256 weth0 = IWETH9(WETH).balanceOf(address(attacker));
        uint160 sqrtBefore = _sqrtPrice(OLD_POOL_ID);

        // LEG 1 - vandalize: dump 460M v1 (roughly a tenth of the launch's own sale) ahead of it.
        attacker.sellV1(p.oldKey, GRIEF_V1);

        // LEG 2 - the batch either aborts below floor (grief succeeded) or absorbs the dump.
        uint256 nonceBefore = safe.nonce();
        (bool ok,) = _launch(p, v2Budget);
        emit log_named_uint("M3: batch executed (0) or aborted (1)", ok ? 0 : 1);
        if (ok) {
            // The launch absorbed a 460M-v1 pre-dump WITHOUT tripping the 0.5% floor.
            uint256 shortfall = simRaised - settler.wethRaised();
            emit log_named_uint("M3: shortfall vs simulation (wei WETH)", shortfall);
            emit log_named_uint("M3: floor margin (wei WETH)", simRaised - p.minWethOut);
            assertTrue(settler.wethRaised() >= p.minWethOut, "M3: launch executed below its own floor");
            attacker.buyV1ExactOut(p.oldKey, GRIEF_V1);
            emit log_named_uint(
                "M3: grief-attempt round-trip delta, + is profit (wei WETH)",
                IWETH9(WETH).balanceOf(address(attacker)) - weth0
            );
            assertTrue(
                IWETH9(WETH).balanceOf(address(attacker)) <= weth0,
                "M3: the vandal PROFITED from a dump the launch fully absorbed"
            );
            return;
        }

        // The floor tripped: the abort must be clean and the vandal must pay for it.
        _assertLaunchAbortedClean(nonceBefore);

        // TRUE wealth accounting: the buyback may be funded by wrapping raw ETH, so WETH-balance
        // deltas alone double-count. Wealth = WETH balance + raw ETH balance (raw ETH is exactly
        // pre-wrapped WETH). Path independence means dump + buy-back-your-own-impact is ~neutral:
        // the honest grief price is LP/hook fees + gas, NOT the tranche's mark-to-market move.
        uint256 proceeds = IWETH9(WETH).balanceOf(address(attacker)) - weth0;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 preValue = Math.mulDiv(GRIEF_V1, 1 << 192, uint256(sqrtBefore) * uint256(sqrtBefore));
        emit log_named_uint("M3: launch ABORTED below floor", 1);
        emit log_named_uint("M3: tranche pre-dump value (wei WETH)", preValue);
        emit log_named_uint("M3: dump proceeds (wei WETH)", proceeds);

        uint256 wealthBefore = weth0 + address(attacker).balance;
        try attacker.buyV1ExactOut(p.oldKey, GRIEF_V1) {
            assertTrue(IERC20(V1).balanceOf(address(attacker)) == GRIEF_V1, "M3: inventory not restored on unwind");
            uint256 wealthAfter = IWETH9(WETH).balanceOf(address(attacker)) + address(attacker).balance;
            emit log_named_uint(
                "M3: unwind fees+gas, the TRUE price of the grief (wei WETH)", wealthBefore - wealthAfter
            );
            assertTrue(wealthAfter <= wealthBefore, "M3: the vandal PROFITED from a fully unwound grief");
        } catch {
            emit log_named_uint("M3: unwind impossible; vandal is stuck short the dumped tranche", 1);
        }
        assertTrue(proceeds < preValue, "M3: the grief was free; the vandal sold at or above market");
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _armedAttacker() private returns (MevAttacker attacker) {
        attacker = new MevAttacker{value: SEARCHER_ETH}(POOL_MANAGER);
        assertTrue(IERC20(V1).balanceOf(SEARCHER_V1_WHALE) >= SEARCHER_V1, "the searcher's v1 whale is dry at the pin");
        vm.prank(SEARCHER_V1_WHALE);
        assertTrue(IERC20(V1).transfer(address(attacker), SEARCHER_V1), "arm the searcher");
    }

    /// @dev A reverted batch must leave the world exactly as it was: nothing activated, nothing
    ///      minted, no v1 moved, no Safe nonce burned - the launch can simply be re-signed.
    function _assertLaunchAbortedClean(uint256 nonceBefore) private view {
        assertTrue(!vault.claimsActive(), "M: claims activated by a failed batch");
        assertTrue(v2.totalSupply() == 0, "M: v2 minted by a failed batch");
        assertTrue(IERC20(V1).balanceOf(address(settler)) == 0, "M: v1 reached the settler");
        assertTrue(
            IERC20(V1).balanceOf(address(vault)) == vault.totalDepositedV1() - vault.totalLedgerWithdrawnV1(),
            "M: deposited v1 left the vault"
        );
        assertTrue(safe.nonce() == nonceBefore, "M: the Safe's nonce advanced on a failed batch");
        assertTrue(
            vault.rootCommittedAt() + vault.EXECUTION_WINDOW() > block.timestamp,
            "M: outside the execution window; a re-sign is impossible"
        );
    }

    function _reportRoundTrip(
        string memory tag,
        uint256 wethBefore,
        uint256 wethAfter,
        uint256 v1Expected,
        MevAttacker attacker
    ) private {
        assertTrue(
            IERC20(V1).balanceOf(address(attacker)) == v1Expected, string.concat(tag, ": v1 inventory not restored")
        );
        assertTrue(wethAfter <= wethBefore, string.concat(tag, ": the searcher profited with no launch executed"));
        emit log_named_uint(string.concat(tag, ": round-trip cost to searcher (wei WETH)"), wethBefore - wethAfter);
    }
}
