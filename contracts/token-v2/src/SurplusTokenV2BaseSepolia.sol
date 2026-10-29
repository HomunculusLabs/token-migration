// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    ERC20CappedUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title SurplusTokenV2
/// @notice Base-canonical successor ERC-20 behind an ERC1967 proxy that is initialized in its constructor.
///         Name, symbol and cap are deployment parameters; supply starts at zero.
/// @dev The governance Safe holds every role, upgrade authority included, and the deploying account holds
///      none. Storage is append-only across upgrades: see DESIGN.md and storage-layout.json.
contract SurplusTokenV2BaseSepolia is ERC20CappedUpgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    error InvalidCanonicalChain(uint256 actual);
    error InvalidGovernance();
    error InvalidMetadata();
    error ZeroEpoch();

    uint256 public constant CANONICAL_CHAIN_ID = 84532;
    // Role ids are `_roles` keys: a successor that changes a preimage string orphans that role's holders.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice What `mintRemainingThisEpoch()` reports while no limit is engaged. The ENGAGED
    ///         state uses 0 as its "unconstrained" encoding: `_mintLimitPerEpoch == 0` is the
    ///         storage-zero default, so the token is launch-safe by construction (a disabled
    ///         limiter is what the atomic launch batch needs, and it is what fresh storage gives).
    uint256 public constant NO_MINT_LIMIT = type(uint256).max;

    // --- Mint limiter (engaged post-launch by the Safe; see DESIGN.md "Mint limiter") ---
    // Epoch throttle on mint velocity: at most `mintLimitPerEpoch` is mintable per `epochLength`
    // seconds. `_mintLimitPerEpoch == 0` (the storage default) means NO constraint — the state the
    // atomic launch batch mints under: the whole migrated supply plus the LP budget in one
    // transaction. The Safe lifts the limit by setting it back to 0. Storage appended BEFORE
    // __gap; the gap is resized, not reordered.
    uint256 private _mintLimitPerEpoch; // 0 (storage default) until the Safe engages a limit
    uint256 private _epochLength; // seconds; 0 until the grid is fixed by the first engage
    uint256 private _epochAnchor; // timestamp epoch 0 started at, when the grid was fixed
    uint256 private _mintedInEpoch; // minted in the CURRENT epoch only; hard-reset each epoch

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param governance The Safe. It receives every role; the account deploying the proxy receives none.
    function initialize(string memory name_, string memory symbol_, uint256 cap_, address governance)
        external
        initializer
    {
        if (block.chainid != CANONICAL_CHAIN_ID) revert InvalidCanonicalChain(block.chainid);
        // Rejects an EOA or a mistyped address; code at the address does not prove it is the intended Safe.
        if (governance.code.length == 0) revert InvalidGovernance();
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert InvalidMetadata();

        __ERC20_init(name_, symbol_);
        __ERC20Capped_init(cap_);
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, governance);
        _grantRole(MINTER_ROLE, governance);
        _grantRole(BURNER_ROLE, governance);
        _grantRole(UPGRADER_ROLE, governance);
    }

    /// @notice The only way tokens come into existence; `totalSupply + amount` may not exceed the cap.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _checkMintLimit(amount);
        _mint(to, amount);
    }

    // ----------------------------------------------------------------------------------------
    // Mint limiter
    // ----------------------------------------------------------------------------------------

    event MintLimitSet(uint256 limitPerEpoch, uint256 epochLength, uint256 effectiveFrom);

    /// @notice Engage, tune or lift the mint throttle. DEFAULT_ADMIN_ROLE (the Safe) only.
    /// @dev  `limitPerEpoch == 0` lifts the limit entirely. `epochLength` is fixed by
    ///       the FIRST engage call (the epoch grid must not move once minting counts against it);
    ///       later calls may only change `limitPerEpoch`, keeping the same grid and anchor. A limit
    ///       is only ever engaged POST-launch: while unset, mints are not tracked, so the launch
    ///       batch mints backing + LP budget in one transaction; engagement starts a FRESH epoch
    ///       budget (nothing retroactive). Lowering the limit below what this epoch already minted
    ///       simply zeroes the remaining budget until the next epoch — it never underflows.
    function setMintLimit(uint256 limitPerEpoch, uint256 epochLength) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_epochLength == 0) {
            if (epochLength == 0) revert ZeroEpoch();
            _epochLength = epochLength;
            _epochAnchor = block.timestamp; // epoch 0 starts now; grid fixed forever
        } else if (epochLength != _epochLength) {
            // Grid already fixed by the first engage: immutable from then on.
            revert EpochGridFixed(_epochLength, epochLength);
        }
        _mintLimitPerEpoch = limitPerEpoch;
        emit MintLimitSet(limitPerEpoch, _epochLength, block.timestamp);
    }

    /// @notice Remaining mintable amount in the current epoch (NO_MINT_LIMIT while unconstrained).
    function mintRemainingThisEpoch() external view returns (uint256) {
        uint256 limit = _mintLimitPerEpoch;
        if (limit == 0) return NO_MINT_LIMIT;
        uint256 spent = _epochIndex() == 0 ? _mintedInEpoch : 0;
        return spent >= limit ? 0 : limit - spent;
    }

    /// @dev Applies the epoch throttle. While unconstrained this is one warm SLOAD + compare.
    function _checkMintLimit(uint256 amount) private {
        uint256 limit = _mintLimitPerEpoch;
        if (limit == 0) return; // unconstrained: storage-zero default, what launch mints under
        uint256 spent = _epochIndex() == 0 ? _mintedInEpoch : 0;
        // spent can exceed limit only if the Safe LOWERED the limit mid-epoch: then the
        // remaining budget is zero until the next epoch. Never `limit - spent` raw.
        uint256 remaining = spent >= limit ? 0 : limit - spent;
        if (amount > remaining) revert MintLimitExceeded(amount, remaining);
        if (spent == 0 && _epochIndex() != 0) {
            // First mint of a later epoch: advance the anchor to the current epoch (grid kept),
            // and open it with this amount. Hard reset: unused allowance does not roll over.
            _epochAnchor += _epochIndex() * _epochLength;
            _mintedInEpoch = amount;
        } else {
            _mintedInEpoch = spent + amount;
        }
    }

    /// @dev Current epoch index relative to the anchor; 0 while inside epoch 0.
    function _epochIndex() private view returns (uint256) {
        return (block.timestamp - _epochAnchor) / _epochLength; // _epochLength > 0 whenever reachable
    }

    error MintLimitExceeded(uint256 requested, uint256 remaining);
    error EpochGridFixed(uint256 fixedLength, uint256 attempted);

    /// @notice Destroys `amount` of the caller's own balance and lowers totalSupply. A buyback needs this:
    ///         tokens sent to a dead address are locked, not burned.
    /// @dev The cap bounds outstanding supply, not lifetime issuance, so a burn frees that much mint headroom.
    ///      Gated so that supply changes only by governed action; the Safe can grant the role to an executor.
    function burn(uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(_msgSender(), amount);
    }

    /// @dev UPGRADER_ROLE can replace every rule in this contract, the cap included.
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // Reserved for successor state; the inherited OZ modules keep their own gaps. Shrunk by the
    // limiter's four slots (appended above, after every inherited field — nothing reordered).
    uint256[46] private __gap;
}
