// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MigrationSettler} from "./MigrationSettler.sol";

/// @dev The slice of MigrationVault (contracts/migration) the launch calls and checks.
interface ILaunchVault {
    function owner() external view returns (address);
    // forge-lint: disable-next-line(mixed-case-function)
    function V1() external view returns (address);
    // forge-lint: disable-next-line(mixed-case-function)
    function V2() external view returns (address);
    function totalClaimable() external view returns (uint256);
    function totalDepositedV1() external view returns (uint256);
    function totalLedgerWithdrawnV1() external view returns (uint256);
    function activateClaims() external;
    function withdrawV1ForSettlement(address to, uint256 amount) external;
    function verifySettlement()
        external
        view
        returns (bool backed, uint256 v2Balance, uint256 claimable, uint256 v1InCustody, bool active, uint256 claimed);
}

/// @dev SurplusTokenV2 (contracts/token-v2): `mint` needs MINTER_ROLE, which only the Safe holds.
interface ILaunchToken {
    function mint(address to, uint256 amount) external;
}

/// @dev The Safe 1.4.1 views the launch reads to prove it left the Safe's settings as they were.
interface ISafeSettings {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);
    function getStorageAt(uint256 offset, uint256 length) external view returns (bytes memory);
}

/**
 * @title MigrationLaunch
 * @notice The SURPLUS v2 launch as one contract. The Safe signs ONE transaction, a DELEGATECALL to `launch()`,
 *         which runs these five steps as the Safe, in this order, all or nothing:
 *         1. mint V2_FOR_CLAIMS v2 into the vault: the backing for every claim;
 *         2. vault.activateClaims(): claims open;
 *         3. vault.withdrawV1ForSettlement(SETTLER, V1_FOR_SALE): the migrated v1 goes to the settler;
 *         4. mint V2_FOR_POOL v2 to the settler: the v2 side of the new pool;
 *         5. settler.settle(settleParams()): sell the v1, open the v2/WETH pool at OPEN_TICK, seed it, and mint
 *            every LP NFT to the Safe.
 *         It then checks the result and reverts everything if a check fails. Every number is fixed at
 *         deployment and public: the getters below, and settleParams() for the whole input to step 5.
 *
 * Why a DELEGATECALL, and what keeps it safe:
 * - Only the Safe may mint v2, activate the vault, release its v1 and call settle, so the steps must run as the
 *   Safe. A DELEGATECALL runs this code at the Safe's address, with the Safe's storage.
 * - So this contract holds no state. Every value is an immutable, part of its code. Nothing here writes
 *   storage, delegatecalls or self-destructs, and it calls only the token, the vault, the settler and the
 *   Safe's own views.
 * - `launch()` runs only at SAFE. Called directly, or delegatecalled by any other account, it reverts before
 *   doing anything.
 * - It finishes by proving the Safe's owners, threshold, modules, guard, fallback handler and singleton are
 *   exactly what they were before it ran.
 * - It runs once: a second run reverts at step 2, because claims are already active.
 *
 * The kit deploys this contract through CREATE2, so its address is fixed by its code and its numbers, and runs
 * the exact signed transaction through the Safe on a private fork before anyone signs. A Safe DELEGATECALL to an
 * address with no code succeeds and does nothing, so the contract must be deployed, with the code hash the kit
 * recorded, before the transaction executes.
 */
contract MigrationLaunch {
    /// @notice The addresses, and the two mint amounts. Everything else comes from the settle params.
    struct Config {
        address safe;
        address vault;
        address v2;
        address settler;
        uint256 v2ForClaims; // step 1: must equal the vault's totalClaimable() when the launch runs
        uint256 v2ForPool; // step 4: the signed v2 budget
    }

    /// @dev Safe 1.4.1: the head of the module list, the page read here, and the slots of the singleton, the guard and
    ///      the fallback handler.
    address internal constant SENTINEL_MODULES = address(0x1);
    uint256 internal constant MODULE_PAGE = 10;
    uint256 internal constant SINGLETON_SLOT = 0;
    uint256 internal constant GUARD_SLOT = uint256(keccak256("guard_manager.guard.address"));
    uint256 internal constant FALLBACK_HANDLER_SLOT = uint256(keccak256("fallback_manager.handler.address"));
    /// @dev The init code of a data contract (solmate SSTORE2): copy every byte after this 11-byte prefix into memory
    ///      and return it as the new contract's code.
    bytes internal constant STORE_PREFIX = hex"600B5981380380925939F3";

    address public immutable SAFE;
    address public immutable VAULT;
    address public immutable SETTLER;
    address public immutable V1;
    address public immutable V2;
    address public immutable WETH;
    /// @notice Step 1: the v2 minted into the vault, the backing for every claim (the committed claims total).
    uint256 public immutable V2_FOR_CLAIMS;
    /// @notice Step 3: the v1 released to the settler and sold, the vault's whole net ledger.
    uint256 public immutable V1_FOR_SALE;
    /// @notice Step 4: the v2 minted to the settler for the pool's v2 side. What the side does not use goes back to
    ///         the Safe.
    uint256 public immutable V2_FOR_POOL;
    /// @notice Step 5: the part of V1_FOR_SALE sold on the v3 1% pool. The rest sells on the Doppler pool.
    uint256 public immutable V1_SOLD_ON_V3_TAIL;
    /// @notice Step 5: the least WETH the sale may raise. Less reverts everything.
    uint256 public immutable MIN_WETH_OUT;
    /// @notice Step 5: the new pool opens at exactly this tick's price.
    int24 public immutable OPEN_TICK;
    /// @notice Step 5: the Uniswap v4 id of the new v2/WETH pool (keccak256 of its PoolKey).
    bytes32 public immutable NEW_POOL_ID;
    /// @notice Step 5: the v2 ranges of the pool's v2 side. The launch mints one LP NFT for the WETH side and one for
    ///         each range.
    uint256 public immutable V2_RANGES;
    /// @notice Where the whole settle input is stored: a code-only contract this constructor wrote, holding
    ///         abi.encode(params) after a STOP byte, so a call into it does nothing. settleParams() decodes it.
    address public immutable SETTLE_PARAMS;
    /// @notice keccak256(abi.encode(params)), checked on every read.
    bytes32 public immutable SETTLE_PARAMS_HASH;

    error InvalidLaunch(string reason);
    error NotRunByTheSafe(address context);
    error ClaimsTotalChanged(uint256 totalClaimable, uint256 v2ForClaims);
    error LedgerChanged(uint256 netLedger, uint256 v1ForSale);
    error SettleParamsCorrupt();
    error LaunchCheckFailed(string check);
    error SafeSettingsChanged();

    /// @dev Checks the wiring it can see: the settler and the vault both belong to `c.safe` and name the same tokens.
    constructor(Config memory c, MigrationSettler.Params memory p) {
        MigrationSettler settler = MigrationSettler(c.settler);
        ILaunchVault vault = ILaunchVault(c.vault);
        address v1 = settler.V1();
        if (c.safe == address(0) || settler.SAFE() != c.safe || settler.V2() != c.v2) revert InvalidLaunch("settler");
        if (vault.owner() != c.safe || vault.V2() != c.v2 || vault.V1() != v1) revert InvalidLaunch("vault");
        if (c.v2ForClaims == 0 || c.v2ForPool == 0) revert InvalidLaunch("amounts");
        if (p.v1In == 0 || p.v2Ranges.length == 0) revert InvalidLaunch("params");

        SAFE = c.safe;
        VAULT = c.vault;
        SETTLER = c.settler;
        V1 = v1;
        V2 = c.v2;
        WETH = settler.WETH();
        V2_FOR_CLAIMS = c.v2ForClaims;
        V1_FOR_SALE = p.v1In;
        V2_FOR_POOL = c.v2ForPool;
        V1_SOLD_ON_V3_TAIL = p.tailIn;
        MIN_WETH_OUT = p.minWethOut;
        OPEN_TICK = p.openTick;
        NEW_POOL_ID = keccak256(abi.encode(p.newKey));
        V2_RANGES = p.v2Ranges.length;
        bytes memory encoded = abi.encode(p);
        SETTLE_PARAMS_HASH = keccak256(encoded);
        SETTLE_PARAMS = _store(encoded);
    }

    /// @notice The launch. Runs only as the Safe, through the Safe's DELEGATECALL (see the contract notes).
    function launch() external {
        // In a DELEGATECALL this code runs at the caller's address, which must be SAFE. Called directly, it is this
        // contract's own address.
        if (address(this) != SAFE) revert NotRunByTheSafe(address(this));
        ILaunchVault vault = ILaunchVault(VAULT);
        // The numbers were built for one commitment and one ledger. A launch built for any other must not run.
        uint256 claimable = vault.totalClaimable();
        if (claimable != V2_FOR_CLAIMS) revert ClaimsTotalChanged(claimable, V2_FOR_CLAIMS);
        uint256 ledger = vault.totalDepositedV1() - vault.totalLedgerWithdrawnV1();
        if (ledger != V1_FOR_SALE) revert LedgerChanged(ledger, V1_FOR_SALE);
        MigrationSettler.Params memory p = settleParams();
        bytes32 settingsBefore = _safeSettings();
        uint256 v2SupplyBefore = IERC20(V2).totalSupply();
        uint256 vaultV1Before = IERC20(V1).balanceOf(VAULT);

        // 1. Back every claim.
        ILaunchToken(V2).mint(VAULT, V2_FOR_CLAIMS);
        // 2. Open claims. The vault checks that it holds the backing and that the execution window is still open.
        vault.activateClaims();
        // 3. Release the migrated v1 to the settler. The vault allows this only once claims are active.
        vault.withdrawV1ForSettlement(SETTLER, V1_FOR_SALE);
        // 4. The v2 for the new pool's v2 side.
        ILaunchToken(V2).mint(SETTLER, V2_FOR_POOL);
        // 5. Sell the v1, open the v2/WETH pool at OPEN_TICK, seed it, and mint every LP NFT to the Safe.
        MigrationSettler(SETTLER).settle(p);

        _checkLaunched(v2SupplyBefore, vaultV1Before);
        if (_safeSettings() != settingsBefore) revert SafeSettingsChanged();
    }

    /// @notice The whole input to step 5, as stored at deployment.
    function settleParams() public view returns (MigrationSettler.Params memory) {
        address pointer = SETTLE_PARAMS;
        uint256 size = pointer.code.length - 1;
        bytes memory encoded = new bytes(size);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(encoded, 0x20), 1, size)
        }
        if (keccak256(encoded) != SETTLE_PARAMS_HASH) revert SettleParamsCorrupt();
        return abi.decode(encoded, (MigrationSettler.Params));
    }

    /// @dev What the five steps must have done. The settler checks the sale, the seed and the LP NFTs' owner itself.
    function _checkLaunched(uint256 v2SupplyBefore, uint256 vaultV1Before) internal view {
        (bool backed,, uint256 claimable,, bool active,) = ILaunchVault(VAULT).verifySettlement();
        if (!backed || !active || claimable != V2_FOR_CLAIMS) revert LaunchCheckFailed("claims backed and active");
        if (IERC20(V1).balanceOf(VAULT) != vaultV1Before - V1_FOR_SALE) revert LaunchCheckFailed("v1 released");
        if (IERC20(V2).totalSupply() != v2SupplyBefore + V2_FOR_CLAIMS + V2_FOR_POOL) {
            revert LaunchCheckFailed("v2 minted");
        }
        MigrationSettler settler = MigrationSettler(SETTLER);
        if (settler.wethRaised() < MIN_WETH_OUT) revert LaunchCheckFailed("sale floor");
        if (settler.positionCount() != V2_RANGES + 1) revert LaunchCheckFailed("LP positions");
        if (
            IERC20(V1).balanceOf(SETTLER) != 0 || IERC20(WETH).balanceOf(SETTLER) != 0
                || IERC20(V2).balanceOf(SETTLER) != 0
        ) revert LaunchCheckFailed("settler empty");
    }

    /// @dev Everything that decides who controls the Safe, hashed: owners, threshold, modules, singleton, guard and
    ///      fallback handler, read through the Safe's own views.
    function _safeSettings() internal view returns (bytes32) {
        ISafeSettings safe = ISafeSettings(SAFE);
        (address[] memory modules, address next) = safe.getModulesPaginated(SENTINEL_MODULES, MODULE_PAGE);
        return keccak256(
            abi.encode(
                safe.getOwners(),
                safe.getThreshold(),
                modules,
                next,
                safe.getStorageAt(SINGLETON_SLOT, 1),
                safe.getStorageAt(GUARD_SLOT, 1),
                safe.getStorageAt(FALLBACK_HANDLER_SLOT, 1)
            )
        );
    }

    /// @dev Deploys a contract whose code is 0x00 (STOP) followed by `data`, and returns its address.
    function _store(bytes memory data) private returns (address pointer) {
        bytes memory init = abi.encodePacked(STORE_PREFIX, hex"00", data);
        assembly ("memory-safe") {
            pointer := create(0, add(init, 0x20), mload(init))
        }
        if (pointer == address(0)) revert InvalidLaunch("params store");
    }
}
