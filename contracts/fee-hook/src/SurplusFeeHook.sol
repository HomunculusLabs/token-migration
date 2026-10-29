// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BalanceDeltaLib, HookFlags, PoolKey, SwapParams, IPoolManager as IManager} from "./V4Minimal.sol";

/// @notice Successor-pool swap fee hook for exactly one pool: the official key fixed at deployment.
///         Charges 1.5% of each swap's unspecified-currency amount (the output of an exact-input swap, the
///         input of an exact-output swap), split 0.75% to the team treasury and 0.75% to buybacks.
///         The pool's own LP fee is untouched (pool keyed with a static 0.30% LP fee, 3000 pips):
///         the hook fee is a pure add-on on top of pool math.
/// @dev    Every launch parameter is an immutable, so it lives in the runtime code: whatever reads or places
///         that code (the launch helper's INITIALIZER() check, the CREATE2 deploy, fork-test etches) sees the
///         parameters without any storage.
contract SurplusFeeHook {
    using BalanceDeltaLib for int256;

    /// @notice The v4 permission bits the hook's address must carry, and no others. The PoolManager reads
    ///         permissions from the address: without BEFORE_INITIALIZE the pool gate would silently never run,
    ///         without AFTER_SWAP_RETURNS_DELTA the manager would discard the fee, and an extra bit would make
    ///         the manager call a hook this contract does not implement.
    uint160 public constant REQUIRED_FLAGS =
        HookFlags.BEFORE_INITIALIZE | HookFlags.AFTER_SWAP | HookFlags.AFTER_SWAP_RETURNS_DELTA; // 0x2044
    // v4 pip convention (LPFeeLibrary): 1,000,000 pips = 100%. 1.5% = 15,000 pips.
    uint24 public constant FEE_PIPS = 15_000; // 1.50% total swap fee
    uint24 public constant HALF_PIPS = 7_500; // 0.75% team + 0.75% buyback
    uint256 public constant PIPS_DENOMINATOR = 1_000_000;

    address public immutable POOL_MANAGER;
    /// @notice The treasury Safe: the only account that can withdraw fees.
    address public immutable TREASURY;
    /// @notice The only account that can initialize the official pool (the launch helper).
    address public immutable INITIALIZER;
    // The official pool key, whose hooks field is this contract.
    address public immutable CURRENCY0;
    address public immutable CURRENCY1;
    uint24 public immutable LP_FEE;
    int24 public immutable TICK_SPACING;

    mapping(address currency => uint256) public teamOwed;
    mapping(address currency => uint256) public buybackOwed;
    mapping(address currency => uint256) public teamPaid;
    mapping(address currency => uint256) public buybackPaid;
    mapping(address currency => uint256) public totalTaken;

    error InvalidHookAddress(address hook);
    error ZeroAddress();
    error CurrenciesOutOfOrder(address currency0, address currency1);
    error NotPoolManager(address caller);
    error NotInitializer(address sender);
    error UnofficialPoolKey();
    error NotTreasury(address caller);
    error InsufficientOwed(address currency, uint256 owed, uint256 requested);
    error TransferFailed();
    error NothingToRecover(address currency);

    event FeeTaken(
        address indexed currency, uint256 unspecifiedAmount, uint256 totalTake, uint256 teamTake, uint256 buybackTake
    );
    event TeamWithdrawn(address indexed currency, address indexed to, uint256 amount);
    event BuybackWithdrawn(address indexed currency, address indexed to, uint256 amount);
    event ExcessRecovered(address indexed currency, address indexed to, uint256 amount);

    constructor(
        address poolManager,
        address treasury,
        address initializer,
        address currency0,
        address currency1,
        uint24 lpFee,
        int24 tickSpacing
    ) {
        if ((uint160(address(this)) & HookFlags.ALL_HOOK_MASK) != REQUIRED_FLAGS) {
            revert InvalidHookAddress(address(this));
        }
        // A zero currency is native ETH, which this hook can neither receive nor pay out.
        if (
            poolManager == address(0) || treasury == address(0) || initializer == address(0) || currency0 == address(0)
                || currency1 == address(0)
        ) revert ZeroAddress();
        // v4 only accepts keys with currency0 < currency1; any other order names a pool that can never exist.
        if (currency0 >= currency1) revert CurrenciesOutOfOrder(currency0, currency1);
        POOL_MANAGER = poolManager;
        TREASURY = treasury;
        INITIALIZER = initializer;
        CURRENCY0 = currency0;
        CURRENCY1 = currency1;
        LP_FEE = lpFee;
        TICK_SPACING = tickSpacing;
    }

    /// @notice v4 BEFORE_INITIALIZE hook. Only the initializer can create a pool naming this hook, and only the
    ///         official key: otherwise anyone could initialize the official pool first, at a price of their
    ///         choosing, or attach the hook to any other pool.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view returns (bytes4) {
        if (msg.sender != POOL_MANAGER) revert NotPoolManager(msg.sender);
        if (sender != INITIALIZER) revert NotInitializer(sender);
        if (
            key.currency0 != CURRENCY0 || key.currency1 != CURRENCY1 || key.fee != LP_FEE
                || key.tickSpacing != TICK_SPACING || key.hooks != address(this)
        ) revert UnofficialPoolKey();
        return this.beforeInitialize.selector;
    }

    /// @notice v4 AFTER_SWAP hook. Charges FEE_PIPS of the swap's UNSPECIFIED currency amount, physically
    ///         takes it from pool reserves into this contract, and returns it so the manager bills the
    ///         swapper (swapDelta -= hookDelta).
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, int256 deltaRaw, bytes calldata)
        external
        returns (bytes4, int128)
    {
        if (msg.sender != POOL_MANAGER) revert NotPoolManager(msg.sender);
        // The manager applies a hook's returned delta to the swap's UNSPECIFIED currency: the output of an
        // exact-input swap, the input of an exact-output swap. Charging any other currency leaves the hook
        // owing one currency and credited in the other, and the unlock reverts CurrencyNotSettled.
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        (address feeCurrency, int128 unspecified) =
            specifiedIs0 ? (key.currency1, deltaRaw.amount1()) : (key.currency0, deltaRaw.amount0());
        // Widened to int256 first, so negating any int128 is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 basis = uint256(unspecified < 0 ? -int256(unspecified) : int256(unspecified));
        uint256 take = (basis * FEE_PIPS) / PIPS_DENOMINATOR;
        if (take == 0) return (this.afterSwap.selector, 0);
        uint256 half = take / 2; // team gets the floor half, buyback the rest (the odd wei): they sum to take
        teamOwed[feeCurrency] += half;
        buybackOwed[feeCurrency] += take - half;
        totalTaken[feeCurrency] += take;
        // Collect in the same call: the returned +take is a credit to the hook that must be taken before the
        // unlock ends, or the unlock reverts CurrencyNotSettled. take() needs no sync(); a currency left
        // synced would make any native settle{value:} later in the unlock revert NonzeroNativeValue.
        IManager(POOL_MANAGER).take(feeCurrency, address(this), take);
        emit FeeTaken(feeCurrency, basis, take, half, take - half);
        // take < basis <= 2^127, so it fits in int128.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (this.afterSwap.selector, int128(uint128(take)));
    }

    /// @notice Pays out up to the unpaid team half of `currency`'s fees. Treasury (Safe) only; the Safe picks `to`.
    function withdrawTeam(address currency, address to, uint256 amount) external {
        if (msg.sender != TREASURY) revert NotTreasury(msg.sender);
        uint256 owed = teamOwed[currency] - teamPaid[currency];
        if (amount > owed) revert InsufficientOwed(currency, owed, amount);
        teamPaid[currency] += amount;
        _transfer(currency, to, amount);
        emit TeamWithdrawn(currency, to, amount);
    }

    /// @notice Pays out up to the unpaid buyback half of `currency`'s fees. Treasury (Safe) only; how the buyback
    ///         is executed is Safe policy, not encoded here.
    function withdrawBuyback(address currency, address to, uint256 amount) external {
        if (msg.sender != TREASURY) revert NotTreasury(msg.sender);
        uint256 owed = buybackOwed[currency] - buybackPaid[currency];
        if (amount > owed) revert InsufficientOwed(currency, owed, amount);
        buybackPaid[currency] += amount;
        _transfer(currency, to, amount);
        emit BuybackWithdrawn(currency, to, amount);
    }

    /// @notice Returns tokens sent to the hook outside a swap (a mistaken transfer, dust): the balance above the
    ///         fees still owed. Treasury (Safe) only; the Safe returns it to the sender. No owed fee can leave
    ///         this way.
    function recoverExcess(address currency, address to) external {
        if (msg.sender != TREASURY) revert NotTreasury(msg.sender);
        uint256 unpaid = (teamOwed[currency] - teamPaid[currency]) + (buybackOwed[currency] - buybackPaid[currency]);
        (bool ok, bytes memory ret) = currency.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        uint256 balance = ok && ret.length >= 32 ? abi.decode(ret, (uint256)) : 0;
        if (balance <= unpaid) revert NothingToRecover(currency);
        uint256 excess = balance - unpaid;
        _transfer(currency, to, excess);
        emit ExcessRecovered(currency, to, excess);
    }

    /// @dev Transfers an ERC-20 to a nonzero recipient, accepting an empty or true return value.
    ///      Rejects no-code token addresses: a successful call to an EOA is not a token transfer.
    function _transfer(address token, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert TransferFailed();
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
