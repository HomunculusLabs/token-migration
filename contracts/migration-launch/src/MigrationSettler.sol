// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    ILaunchHook,
    IPermit2,
    IPoolManager,
    IPositionManager,
    IUniswapV3SwapPool,
    IUnlockCallback,
    PoolKey,
    SwapParams
} from "./LaunchInterfaces.sol";
import {LaunchMath} from "./LaunchMath.sol";

/**
 * @title MigrationSettler
 * @notice The settlement leg of the SURPLUS v1→v2 launch, run as ONE call inside the Safe's atomic launch
 *         (MigrationLaunch, or the MultiSendCallOnly batch it replaced). By that point the launch has backed and
 *         activated the vault, released the migrated v1 here, and minted a v2 budget here. `settle` sells the v1 on the two v1 venues
 *         (the Doppler v4 pool and the v3 1% tail). It then initializes the v2/WETH successor pool at the
 *         signed opening tick and seeds it with two single-sided sides that meet at that tick:
 *         - the v2 side, the signed ranges: a copy of the v1 the old pool still offered above its price, the
 *           same amounts over the same ranges on the successor's tick grid, paid from the v2 budget;
 *         - the WETH side, one position from the opening tick to the end of the range, holding the WETH the
 *           sale raised.
 *         Every position is minted straight to the Safe, and the rest goes back to the Safe.
 *
 * - Safe-only.
 * - It calls `PoolManager.initialize` directly. PositionManager.initializePool wraps initialize in
 *   try/catch, so a front-run initialization would be swallowed and our liquidity would go in at the
 *   attacker's price. Here a pre-initialized key reverts PoolAlreadyInitialized, which reverts the whole
 *   Safe batch: nothing is sold, minted or activated.
 * - The signed simulation bounds execution: `minWethOut` is a floor on the sale proceeds, and the v2
 *   budget the batch mints here must cover the signed v2 side. The v2 side does not depend on the sale, so
 *   drift or a sandwich between signing and execution can only move the WETH side, and `minWethOut` bounds
 *   that: a sale below it reverts the batch instead of selling cheap.
 * - The two sides meet exactly at the opening tick: the pool opens at that tick's price, the WETH side starts
 *   there and one v2 range must start there too, so the first trade either way meets liquidity. Each mint caps
 *   the token its side must not hold at zero, so the PositionManager itself proves every position single-sided.
 * - It leaves no approval behind: each is bounded to the amount and the block, and revoked after the mint.
 * - It sells exactly the signed `v1In` and seeds exactly what that sale raised. A donation to this public
 *   address therefore cannot change the seed or block the launch; it goes back to the Safe.
 * - It opens only the decided successor: v2/WETH at the fee and tick spacing pinned at deployment, with a
 *   hook that carries exactly the launch flags, names this contract as its only initializer, charges the
 *   decided 1.5% and pays it to the fee recipient pinned at deployment. A mis-built key reverts; it can never
 *   open a pool without the 1.5% hook, one that pays its fees elsewhere, or one that nothing routes to.
 */
contract MigrationSettler is IUnlockCallback {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    struct Config {
        address poolManager;
        address positionManager;
        address permit2;
        address safe;
        address v1;
        address weth;
        address v2;
        address v3Tail;
        bytes32 oldPoolId;
        uint24 lpFee;
        int24 tickSpacing;
        address feeRecipient; // the successor hook's TREASURY (spec §6.4)
    }

    /// @dev One v2-only position: a range wholly on the v2 side of the opening tick, and its liquidity.
    struct V2Range {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    struct Params {
        PoolKey oldKey; // the v1/WETH Doppler v4 pool; must hash to OLD_POOL_ID
        uint256 v1In; // the v1 the batch releases here; exactly this much is sold
        uint256 tailIn; // the part of v1In sold exact-in on the v3 tail; the rest goes to the v4 pool
        uint160 tailLimit; // v3 sqrt-price limit for the tail sale
        PoolKey newKey; // the v2/WETH successor key
        int24 openTick; // signed opening tick, on the successor's grid; the pool opens at exactly its price
        V2Range[] v2Ranges; // signed v2 side: the copy of the old pool's v1 ladder
        uint256 minWethOut; // signed minimum WETH proceeds
    }

    /// @dev A WETH-side position: the range from the opening tick to the end of the usable range.
    struct Side {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @notice The v4 permission bits the successor hook's address must carry, exactly: BEFORE_INITIALIZE
    ///         (the initializer gate) | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA (the 1.5% fee).
    uint160 public constant HOOK_FLAGS = 0x2044;
    /// @notice The successor hook's fee, in pips (1,000,000 = 100%): the decided 1.5%.
    uint24 public constant HOOK_FEE_PIPS = 15_000;
    /// @dev A v4 hook's permissions ARE the low 14 bits of its address.
    uint160 internal constant ALL_HOOK_MASK = (1 << 14) - 1;
    uint256 internal constant Q96 = 1 << 96;
    /// @dev v4 TickMath.MAX_SQRT_PRICE - 1: selling currency1 moves the price up. A partial fill reverts
    ///      (V1LeftUnsold) and `minWethOut` bounds the proceeds.
    uint160 internal constant MAX_SQRT_PRICE_MINUS_1 = 1461446703485210103287273052203988822378723970341;
    /// @dev v4-periphery Actions.
    bytes1 internal constant MINT_POSITION = 0x02;
    bytes1 internal constant SETTLE_PAIR = 0x0d;

    IPoolManager public immutable POOL_MANAGER;
    IPositionManager public immutable POSITION_MANAGER;
    IPermit2 public immutable PERMIT2;
    address public immutable SAFE;
    address public immutable V1;
    address public immutable WETH;
    address public immutable V2;
    address public immutable V3_TAIL;
    bytes32 public immutable OLD_POOL_ID;
    uint24 public immutable LP_FEE;
    int24 public immutable TICK_SPACING;
    /// @notice The only treasury the successor hook may pay its fees to.
    address public immutable FEE_RECIPIENT;

    /// @notice The launch receipt, read by the post-batch checks (RUNBOOK) and the rehearsal.
    uint256 public wethRaised;
    uint256 public wethSeeded;
    uint256 public v2Seeded;
    /// @notice The first LP NFT the launch minted: the WETH side. The v2 ranges follow it, one id each, in order.
    uint256 public firstPositionId;
    uint256 public positionCount;
    uint128 public wethLiquidity;

    event Settled(
        uint256 v1Sold,
        uint256 wethRaised,
        uint256 wethSeeded,
        uint256 v2Seeded,
        uint256 indexed firstPositionId,
        uint256 positionCount,
        uint128 wethLiquidity
    );

    error InvalidConfig();
    error NotSafe(address caller);
    error NotPoolManager(address caller);
    error NotTailPool(address caller);
    error WrongOldPool(bytes32 poolId);
    error WrongSuccessorKey();
    error WrongHook(address hooks);
    error OpenTickOffGrid(int24 openTick);
    error BadV2Range(uint256 index);
    error V2SideMissesOpen();
    error NothingToSell(uint256 v1In, uint256 tailIn);
    error V1BelowSaleAmount(uint256 balance, uint256 v1In);
    error UnexpectedSwapDelta(int256 amount0, int256 amount1);
    error SettleMismatch(uint256 paid, uint256 owed);
    error V1LeftUnsold(uint256 amount);
    error SaleBelowMinimum(uint256 raised, uint256 minWethOut);
    error V2BudgetExceeded(uint256 need, uint256 budget);
    error PositionNotSafeOwned(uint256 tokenId, address owner);
    error ApprovalLeftBehind(address token);

    constructor(Config memory c) {
        if (
            c.poolManager == address(0) || c.positionManager == address(0) || c.permit2 == address(0)
                || c.safe == address(0) || c.v1 == address(0) || c.weth == address(0) || c.v2 == address(0)
                || c.v3Tail == address(0) || c.v1 == c.weth || c.v1 == c.v2 || c.v2 == c.weth
                || c.oldPoolId == bytes32(0) || c.tickSpacing <= 0
        ) revert InvalidConfig();
        POOL_MANAGER = IPoolManager(c.poolManager);
        POSITION_MANAGER = IPositionManager(c.positionManager);
        PERMIT2 = IPermit2(c.permit2);
        SAFE = c.safe;
        V1 = c.v1;
        WETH = c.weth;
        V2 = c.v2;
        V3_TAIL = c.v3Tail;
        OLD_POOL_ID = c.oldPoolId;
        LP_FEE = c.lpFee;
        TICK_SPACING = c.tickSpacing;
        FEE_RECIPIENT = c.feeRecipient;
    }

    /// @notice Sell `p.v1In` v1, then open and seed the successor pool. Safe-only.
    /// @dev Sells and seeds exactly what the signers simulated, never "whatever this contract holds". The
    ///      address is public, so v1, WETH or v2 sent here before the batch must not change the seed or revert
    ///      the launch. Any such donation goes back to the Safe with the rest.
    function settle(Params calldata p) external {
        if (msg.sender != SAFE) revert NotSafe(msg.sender);
        // Only the pinned Doppler pool is a venue: anyone can open a dust v1/WETH pool, and a simulation run
        // on the same wrong key would sign a floor that does not stop the sale.
        bytes32 oldId = keccak256(abi.encode(p.oldKey));
        if (oldId != OLD_POOL_ID) revert WrongOldPool(oldId);
        _checkSuccessor(p.newKey);
        Side memory weth = _wethSide(p.openTick, p.newKey.currency0 == V2);
        uint256 v2Budget = _balance(V2);
        uint256 v2Need = _checkV2Side(p);
        if (v2Need > v2Budget) revert V2BudgetExceeded(v2Need, v2Budget);

        uint256 raised = _sell(p);
        if (raised < p.minWethOut) revert SaleBelowMinimum(raised, p.minWethOut);
        uint160 openPrice = LaunchMath.sqrtPriceAtTick(p.openTick);
        weth.liquidity = _wethLiquidity(raised, openPrice, weth, p.newKey.currency0 == V2);

        // Directly, and in the same transaction as the mint (see the contract notes).
        POOL_MANAGER.initialize(p.newKey, openPrice);
        _seed(p, weth, raised, v2Budget);
        _returnAll(V1);
        _returnAll(WETH);
        _returnAll(V2);
    }

    /// @dev Mints both sides and records the receipt. The amounts are balance deltas, so a donation is not counted.
    function _seed(Params calldata p, Side memory weth, uint256 raised, uint256 v2Budget) internal {
        uint256 first;
        uint256 wethUsed;
        {
            uint256 wethBefore = _balance(WETH);
            first = _mint(p, weth, raised, v2Budget);
            wethUsed = wethBefore - _balance(WETH);
        }
        uint256 v2Used = v2Budget - _balance(V2);
        wethRaised = raised;
        wethSeeded = wethUsed;
        v2Seeded = v2Used;
        firstPositionId = first;
        positionCount = p.v2Ranges.length + 1;
        wethLiquidity = weth.liquidity;
        emit Settled(p.v1In, raised, wethUsed, v2Used, first, p.v2Ranges.length + 1, weth.liquidity);
    }

    /// @dev The v4 leg of the sale: exact-in v1 (currency1) for WETH (currency0) on the old pool.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager(msg.sender);
        (PoolKey memory key, uint256 amountIn) = abi.decode(data, (PoolKey, uint256));
        int256 delta =
            POOL_MANAGER.swap(key, SwapParams(false, -amountIn.toInt256(), MAX_SQRT_PRICE_MINUS_1), bytes(""));
        int128 wethOut = LaunchMath.amount0(delta);
        int128 v1Paid = LaunchMath.amount1(delta);
        if (wethOut <= 0 || v1Paid >= 0) revert UnexpectedSwapDelta(wethOut, v1Paid);
        // Both casts are exact: v1Paid < 0 and wethOut > 0 were checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 owed = uint256(uint128(-v1Paid));
        POOL_MANAGER.sync(V1);
        IERC20(V1).safeTransfer(address(POOL_MANAGER), owed);
        uint256 paid = POOL_MANAGER.settle();
        if (paid != owed) revert SettleMismatch(paid, owed);
        // forge-lint: disable-next-line(unsafe-typecast)
        POOL_MANAGER.take(WETH, address(this), uint256(uint128(wethOut)));
        return bytes("");
    }

    /// @dev The v3 leg of the sale: v1 (token1) in, WETH (token0) out.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != V3_TAIL) revert NotTailPool(msg.sender);
        if (amount1Delta <= 0 || amount0Delta > 0) revert UnexpectedSwapDelta(amount0Delta, amount1Delta);
        // forge-lint: disable-next-line(unsafe-typecast)
        IERC20(V1).safeTransfer(V3_TAIL, uint256(amount1Delta));
    }

    /// @dev Checked before anything trades. The hook's own beforeInitialize also admits only its official key.
    function _checkSuccessor(PoolKey calldata k) internal view {
        (address c0, address c1) = V2 < WETH ? (V2, WETH) : (WETH, V2);
        if (k.currency0 != c0 || k.currency1 != c1 || k.fee != LP_FEE || k.tickSpacing != TICK_SPACING) {
            revert WrongSuccessorKey();
        }
        if ((uint160(k.hooks) & ALL_HOOK_MASK) != HOOK_FLAGS || k.hooks.code.length == 0) revert WrongHook(k.hooks);
        try ILaunchHook(k.hooks).INITIALIZER() returns (address initializer) {
            if (initializer != address(this)) revert WrongHook(k.hooks);
        } catch {
            revert WrongHook(k.hooks);
        }
        // A pool's hook is fixed for good at initialization, so the fee and where it goes are checked too: a hook
        // bound to this settler that charges nothing, or pays another treasury, must not open the pool.
        try ILaunchHook(k.hooks).TREASURY() returns (address treasury) {
            if (treasury != FEE_RECIPIENT) revert WrongHook(k.hooks);
        } catch {
            revert WrongHook(k.hooks);
        }
        try ILaunchHook(k.hooks).FEE_PIPS() returns (uint24 feePips) {
            if (feePips != HOOK_FEE_PIPS) revert WrongHook(k.hooks);
        } catch {
            revert WrongHook(k.hooks);
        }
    }

    /// @dev The WETH side runs from the opening tick to the end of the usable range, away from the v2 side: below
    ///      the price when WETH is currency1 (v2 sorts first), above it when WETH is currency0.
    function _wethSide(int24 openTick, bool v2Is0) internal view returns (Side memory s) {
        int24 edge = _edge();
        if (openTick % TICK_SPACING != 0 || openTick <= -edge || openTick >= edge) revert OpenTickOffGrid(openTick);
        (s.tickLower, s.tickUpper) = v2Is0 ? (-edge, openTick) : (openTick, edge);
    }

    /// @dev Every v2 range must lie wholly on the v2 side of the opening tick, on the grid, with liquidity, and one
    ///      must start at the opening tick so the two sides meet with no gap. Ranges on the v2 side hold only v2 at
    ///      the opening price, so the amount each needs depends on its bounds alone, not on the sale.
    /// @return need the v2 the ranges take, rounded up as the PoolManager rounds
    function _checkV2Side(Params calldata p) internal view returns (uint256 need) {
        bool v2Is0 = p.newKey.currency0 == V2;
        int24 edge = _edge();
        bool meetsOpen;
        for (uint256 i; i < p.v2Ranges.length; ++i) {
            V2Range calldata r = p.v2Ranges[i];
            bool onV2Side = v2Is0 ? r.tickLower >= p.openTick : r.tickUpper <= p.openTick;
            if (
                !onV2Side || r.liquidity == 0 || r.tickLower >= r.tickUpper || r.tickLower < -edge || r.tickUpper > edge
                    || r.tickLower % TICK_SPACING != 0 || r.tickUpper % TICK_SPACING != 0
            ) revert BadV2Range(i);
            if ((v2Is0 ? r.tickLower : r.tickUpper) == p.openTick) meetsOpen = true;
            uint256 lower = LaunchMath.sqrtPriceAtTick(r.tickLower);
            uint256 upper = LaunchMath.sqrtPriceAtTick(r.tickUpper);
            // v4 SqrtPriceMath.getAmount0Delta / getAmount1Delta with roundUp.
            need += v2Is0
                ? Math.ceilDiv(Math.mulDiv(uint256(r.liquidity) << 96, upper - lower, upper, Math.Rounding.Up), lower)
                : Math.mulDiv(r.liquidity, upper - lower, Q96, Math.Rounding.Up);
        }
        if (!meetsOpen) revert V2SideMissesOpen();
    }

    /// @return raised the WETH this sale produced, as a balance delta so that pre-existing WETH is not counted.
    function _sell(Params calldata p) internal returns (uint256 raised) {
        if (p.v1In <= p.tailIn) revert NothingToSell(p.v1In, p.tailIn);
        uint256 v1Before = _balance(V1);
        if (v1Before < p.v1In) revert V1BelowSaleAmount(v1Before, p.v1In);
        uint256 wethBefore = _balance(WETH);
        POOL_MANAGER.unlock(abi.encode(p.oldKey, p.v1In - p.tailIn));
        if (p.tailIn != 0) {
            IUniswapV3SwapPool(V3_TAIL).swap(address(this), false, p.tailIn.toInt256(), p.tailLimit, bytes(""));
        }
        // Exact-in fills completely unless a price limit stops it; a partial fill must not launch.
        uint256 unsold = _balance(V1) - (v1Before - p.v1In);
        if (unsold != 0) revert V1LeftUnsold(unsold);
        raised = _balance(WETH) - wethBefore;
    }

    /// @dev The liquidity `wethIn` funds on the WETH side, less a 1e-6 haircut because the PositionManager rounds the
    ///      amount up. Below the price (WETH is currency1) amount1 = L * (price - lower) / 2^96; above it (WETH is
    ///      currency0) amount0 = L * 2^96 * (upper - price) / (price * upper).
    function _wethLiquidity(uint256 wethIn, uint160 price, Side memory s, bool v2Is0) internal pure returns (uint128) {
        uint256 l;
        if (v2Is0) {
            l = Math.mulDiv(wethIn, Q96, price - LaunchMath.sqrtPriceAtTick(s.tickLower));
        } else {
            uint256 upper = LaunchMath.sqrtPriceAtTick(s.tickUpper);
            l = Math.mulDiv(Math.mulDiv(wethIn, price, Q96), upper, upper - price);
        }
        l -= l / 1_000_000 + 1;
        return l.toUint128();
    }

    /// @dev One PositionManager call: MINT_POSITION for the WETH side, one per v2 range, then SETTLE_PAIR. The WETH
    ///      mint caps v2 at zero and every v2 mint caps WETH at zero, so a position that is not single-sided at the
    ///      opening price reverts the batch.
    function _mint(Params calldata p, Side memory weth, uint256 wethMax, uint256 v2Max)
        internal
        returns (uint256 first)
    {
        _approve(WETH, wethMax);
        _approve(V2, v2Max);
        bool v2Is0 = p.newKey.currency0 == V2;
        uint256 n = p.v2Ranges.length;
        bytes memory actions = new bytes(n + 2);
        bytes[] memory params = new bytes[](n + 2);
        actions[0] = MINT_POSITION;
        params[0] = _mintParams(
            p.newKey, weth.tickLower, weth.tickUpper, weth.liquidity, v2Is0 ? 0 : wethMax, v2Is0 ? wethMax : 0
        );
        for (uint256 i; i < n; ++i) {
            V2Range calldata r = p.v2Ranges[i];
            actions[i + 1] = MINT_POSITION;
            params[i + 1] =
                _mintParams(p.newKey, r.tickLower, r.tickUpper, r.liquidity, v2Is0 ? v2Max : 0, v2Is0 ? 0 : v2Max);
        }
        actions[n + 1] = SETTLE_PAIR;
        params[n + 1] = abi.encode(p.newKey.currency0, p.newKey.currency1);
        first = POSITION_MANAGER.nextTokenId();
        POSITION_MANAGER.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
        _revoke(WETH);
        _revoke(V2);
        for (uint256 id = first; id <= first + n; ++id) {
            address owner = POSITION_MANAGER.ownerOf(id);
            if (owner != SAFE) revert PositionNotSafeOwned(id, owner);
        }
    }

    function _mintParams(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liq,
        uint256 max0,
        uint256 max1
    ) internal view returns (bytes memory) {
        return abi.encode(key, tickLower, tickUpper, uint256(liq), max0.toUint128(), max1.toUint128(), SAFE, bytes(""));
    }

    /// @dev The largest usable tick at this spacing (MAX_TICK rounded down to the grid); the smallest is its negative.
    function _edge() internal view returns (int24) {
        return LaunchMath.MAX_TICK - LaunchMath.MAX_TICK % TICK_SPACING;
    }

    /// @dev ERC20 → Permit2 → PositionManager, the path SETTLE_PAIR pays through. Bounded to `amount` and to
    ///      this block (Permit2 reads expiration 0 as "now").
    function _approve(address token, uint256 amount) internal {
        IERC20(token).forceApprove(address(PERMIT2), amount);
        PERMIT2.approve(token, address(POSITION_MANAGER), amount.toUint160(), 0);
    }

    /// @dev Revokes both legs of `_approve` and proves they are gone.
    function _revoke(address token) internal {
        IERC20(token).forceApprove(address(PERMIT2), 0);
        PERMIT2.approve(token, address(POSITION_MANAGER), 0, 0);
        (uint160 permitted,,) = PERMIT2.allowance(address(this), token, address(POSITION_MANAGER));
        if (permitted != 0 || IERC20(token).allowance(address(this), address(PERMIT2)) != 0) {
            revert ApprovalLeftBehind(token);
        }
    }

    function _returnAll(address token) internal {
        uint256 amount = _balance(token);
        if (amount != 0) IERC20(token).safeTransfer(SAFE, amount);
    }

    function _balance(address token) internal view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
