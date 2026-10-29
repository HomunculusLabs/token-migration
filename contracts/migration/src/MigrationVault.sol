// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title MigrationVault
 * @notice Custodies SURPLUS v1 deposits and pays v2 claims or ledger-based v1 refunds.
 * @dev The deposit ledger freezes after DEPOSIT_DEADLINE. Claims activate only with a committed
 *      Merkle root and full v2 backing; only then may deposited v1 leave for settlement. Activation
 *      permanently disables refunds, even if an optional claim window later expires.
 *      Before activation, cancellation or permissionless timeouts unlock v1 ledger refunds.
 *
 *      An optional flat-ratio claim path uses the same ledger and shares payout accounting with
 *      Merkle claims. The Safe's atomic launch batch handles settlement and successor-pool creation
 *      outside this vault. See DESIGN.md for allocation requirements, phase boundaries and owner powers.
 */
contract MigrationVault {
    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error NotOwner();
    error NotOpen();
    error NotRefundPhase();
    error LedgerWithdrawalsFrozen();
    error DepositWindowClosed();
    error DeadlineNotPassed(uint256 deadline, uint256 now);
    error DeadlineTooSoon(uint256 deadline, uint256 now);
    error InvalidCommitDeadline(uint256 commitDeadline, uint256 depositDeadline);
    error CommitWindowClosed(uint256 deadline, uint256 now);
    error CommitWindowStillOpen(uint256 deadline, uint256 now);
    error AlreadyCommitted();
    error NotCommitted();
    error ClaimsNotActive();
    error ClaimsAlreadyActive();
    error ClaimsExpiredTerminal();
    error ClaimWindowEnded(uint256 deadline, uint256 now);
    error ClaimsStillActive();
    error ClaimWindowStillOpen(uint256 deadline, uint256 now);
    error ExecutionWindowStillOpen(uint256 deadline, uint256 now);
    error ExecutionWindowEnded(uint256 deadline, uint256 now);
    error WindowTooLong();
    error ExceedsTotalClaimable(uint256 amount, uint256 remaining);
    error NothingToWithdraw();
    error InvalidProof();
    error AlreadyClaimed(uint256 index);
    error InsufficientBacking(uint256 required, uint256 available);
    error NothingToSweep();
    error NothingToRescue();
    error ExcessiveWithdrawal(uint256 requested, uint256 available);
    error ProRataDisabled();
    error AlreadyClaimedAccount(address account);
    error NothingToClaim();
    error ProRataTotalMismatch(uint256 expected, uint256 actual);

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    /// @notice A v1 deposit was credited. `totalCredited` is the account's aggregated credit.
    event DepositIssued(address indexed account, uint256 amount, uint256 totalCredited);

    /// @notice A v1 ledger withdrawal was paid to the account.
    event LedgerWithdrawn(address indexed account, uint256 amount);

    /// @notice Records this deposit and the account's remaining ledger credit after it.
    /// @dev `cumulativeCredited` equals `credited - withdrawn`, not gross deposits.
    event DepositReceipt(address indexed account, uint256 netCredited, uint256 cumulativeCredited);

    /// @notice Records a ledger withdrawal or refund and the account's remaining credit after it.
    /// @dev Together with {DepositReceipt}, lets an indexer reconcile every ledger mutation.
    event WithdrawalReceipt(address indexed account, uint256 amount, uint256 cumulativeCredited);

    /// @notice The deposit window closed and the allocation root was committed. From here only v2
    ///         claims, or ledger refunds after the execution timeout, resolve the migration.
    event RootCommitted(bytes32 indexed root, uint256 totalClaimable);

    /// @notice Claims went live. Only emitted after the vault verified it holds enough v2 to cover
    ///         every outstanding entitlement — the "claims live only when fully backed" gate.
    event ClaimsActivated(uint256 backingBalance, uint256 claimWindowEnd);

    /// @notice The claim window ended. Only a deployment with CLAIM_PERIOD > 0 can emit this; the
    ///         unclaimed remainder then becomes sweepable to the owner.
    event ClaimsExpired();

    /// @notice The migration was cancelled by the owner before root commitment.
    event MigrationCancelled();

    /// @notice No root was committed by COMMIT_DEADLINE. Opened permissionlessly; ledger refunds
    ///         are now live.
    event CommitExpired();

    /// @notice The execution window expired without claims being activated. Opened permissionlessly;
    ///         ledger refunds are now live.
    event ExecutionExpired();

    /// @notice A v2 claim was paid to its committed beneficiary. `index` is the leaf index.
    event ClaimPaid(uint256 indexed index, address indexed account, uint256 amount);

    /// @notice A proofless flat-ratio claim was paid to the caller from its ledger entitlement.
    event ProRataClaimed(address indexed account, uint256 amount);

    /// @notice A v1 refund of the account's whole remaining ledger credit was paid to it.
    event RefundPaid(address indexed account, uint256 amount);

    /// @notice v2 that no claimant can still be owed was swept to the owner.
    event Swept(address indexed to, uint256 amount);

    /// @notice v1 was withdrawn to the settlement executor for the sale leg. Only possible after
    ///         claims are active (see the ordering rule in the contract header).
    event SettlementWithdrawn(address indexed to, uint256 amount);

    /// @notice v1 that reached the vault without a deposit was returned by the owner.
    event V1Rescued(address indexed to, uint256 amount);

    event OwnershipTransferStarted(address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    enum Phase {
        Open, // deposits and ledger withdrawals
        Committed, // root committed; bounded execution window; no deposits, no ledger withdrawals
        Cancelled // cancelled, or execution-expired: every depositor exits through the ledger
    }

    // ---------------------------------------------------------------------------------------------
    // Immutable configuration
    // ---------------------------------------------------------------------------------------------

    IERC20 public immutable V1;
    IERC20 public immutable V2;
    /// @notice Last block.timestamp at which a deposit is credited, or a ledger withdrawal made,
    ///         while the vault is Open. Inclusive.
    uint256 public immutable DEPOSIT_DEADLINE;
    /// @notice Last block.timestamp at which the owner may commit the root. Past it, anyone may
    ///         cancel the migration and every depositor is refunded from the ledger — the timeout
    ///         that keeps the post-deadline freeze from trapping deposits behind a silent Safe.
    uint256 public immutable COMMIT_DEADLINE;
    /// @notice Seconds after root commitment during which the operator must activate claims.
    ///         If it passes without activation, anyone may open ledger refunds permissionlessly —
    ///         the enforced timeout right that does not depend on signer liveness.
    uint256 public immutable EXECUTION_WINDOW;
    /// @notice Duration of the claim window, fixed at deployment and part of the published offer.
    ///         0 means claims never expire and no entitlement can ever be swept. A positive value
    ///         means claims expire that many seconds after activation, and the owner may then
    ///         sweep whatever is still unclaimed.
    uint256 public immutable CLAIM_PERIOD;

    /// @notice Immutable migration ratio: {claimProRata} pays
    ///         `net ledger credit × MIGRATION_RATE_BPS / 10_000` v2, rounded down.
    uint256 public immutable MIGRATION_RATE_BPS;

    /// @notice Enables the ledger-based {claimProRata} path alongside Merkle claims.
    /// @dev {commitRoot} checks the aggregate ratio total, not individual leaves. The off-chain
    ///      allocation must contain one leaf per account matching the formula and reconcile its
    ///      sum to that total. Disable this path for per-holder adjustments or rounding bumps.
    bool public immutable PRO_RATA_ENABLED;

    // ---------------------------------------------------------------------------------------------
    // Mutable state
    // ---------------------------------------------------------------------------------------------

    Phase public phase = Phase.Open;
    address public owner;
    address public pendingOwner;

    bytes32 public root; // bytes32(0) until committed
    uint256 public rootCommittedAt;
    uint256 public totalClaimable; // Σ leaf amounts under `root`
    uint256 public totalClaimedAmount; // Total v2 paid through both claim paths.
    bool public claimsActive;
    bool public claimsExpired; // Terminal: expiry cannot be undone.
    bool public claimsEverActive; // Activation permanently closes the refund path.
    uint256 public claimWindowEnd; // 0 until claims activate; past it, claims close and sweep opens

    uint256 public totalDepositedV1; // Σ gross credits (ledger accounting)
    uint256 public totalLedgerWithdrawnV1; // Σ ledger exits: withdrawV1 + refund

    mapping(address account => uint256 credited) public credited;
    mapping(address account => uint256 withdrawn) public withdrawn;
    mapping(uint256 wordIndex => uint256 word) private _claimedBitmap;

    // With pro-rata enabled, the claim paths exclude each other for the same account.
    // `_resolvedViaRoot` is set-only: multiple Merkle leaves may still pay one account.
    // Refunds use the v1 ledger and are unreachable after claim activation.
    mapping(address account => bool resolved) private _resolvedViaRoot;
    mapping(address account => bool claimed) private _claimedViaProRata;

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    constructor(
        IERC20 v1,
        IERC20 v2,
        uint256 depositDeadline,
        uint256 commitDeadline,
        uint256 executionWindow,
        uint256 claimPeriod,
        uint256 migrationRateBps,
        bool proRataEnabled,
        address initialOwner
    ) {
        if (address(v1) == address(0) || address(v2) == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();
        if (depositDeadline <= block.timestamp) revert DeadlineTooSoon(depositDeadline, block.timestamp);
        if (commitDeadline <= depositDeadline) revert InvalidCommitDeadline(commitDeadline, depositDeadline);
        if (executionWindow == 0) revert ZeroAmount();
        // Every deadline sum must fit, or its timeout call would panic forever: rootCommittedAt (at most
        // commitDeadline) + executionWindow in expireExecution, and activation time (at most that execution
        // deadline) + claimPeriod in activateClaims.
        if (executionWindow > type(uint256).max - commitDeadline) revert WindowTooLong();
        if (claimPeriod > type(uint256).max - commitDeadline - executionWindow) revert WindowTooLong();
        // A zero rate with the proofless path enabled could only ever pay zeroes.
        if (proRataEnabled && migrationRateBps == 0) revert ZeroAmount();

        V1 = v1;
        V2 = v2;
        DEPOSIT_DEADLINE = depositDeadline;
        COMMIT_DEADLINE = commitDeadline;
        EXECUTION_WINDOW = executionWindow;
        CLAIM_PERIOD = claimPeriod;
        MIGRATION_RATE_BPS = migrationRateBps;
        PRO_RATA_ENABLED = proRataEnabled;
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    // ---------------------------------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Deposits and ledger withdrawals (Open phase)
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Deposit `amount` of v1 and credit `msg.sender`. Repeated deposits aggregate.
     * @dev Credit follows the token-supplying caller, including contract wallets, not tx.origin
     *      or a separate gas payer. Deposited v1 cannot leave for settlement while Open.
     */
    function deposit(uint256 amount) external {
        if (phase != Phase.Open) revert NotOpen();
        if (block.timestamp > DEPOSIT_DEADLINE) revert DepositWindowClosed();
        if (amount == 0) revert ZeroAmount();

        SafeERC20.safeTransferFrom(V1, msg.sender, address(this), amount);
        credited[msg.sender] += amount;
        totalDepositedV1 += amount;

        emit DepositIssued(msg.sender, amount, credited[msg.sender]);
        emit DepositReceipt(msg.sender, amount, credited[msg.sender] - withdrawn[msg.sender]);
    }

    /**
     * @notice Withdraw available v1 credit while Open through the deposit deadline, or when Cancelled.
     * @dev The ledger freezes after the deadline so withdrawals cannot invalidate the snapshot or
     *      the pro-rata total. Permissionless timeouts unlock refunds if the owner does not launch.
     *      This function and {refund} debit the same ledger to prevent duplicate v1 payouts.
     */
    function withdrawV1(uint256 amount) external {
        if (phase == Phase.Committed || (phase == Phase.Open && block.timestamp > DEPOSIT_DEADLINE)) {
            revert LedgerWithdrawalsFrozen();
        }
        if (amount == 0) revert ZeroAmount();

        uint256 available = credited[msg.sender] - withdrawn[msg.sender];
        if (amount > available) revert ExcessiveWithdrawal(amount, available);

        withdrawn[msg.sender] += amount;
        totalLedgerWithdrawnV1 += amount;
        SafeERC20.safeTransfer(V1, msg.sender, amount);

        emit LedgerWithdrawn(msg.sender, amount);
        emit WithdrawalReceipt(msg.sender, amount, credited[msg.sender] - withdrawn[msg.sender]);
    }

    // ---------------------------------------------------------------------------------------------
    // Operator phase control
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Close the window and commit the allocation root. Point of no return.
     * @param root_           Merkle root over leaves keccak256(abi.encodePacked(index, account, amount))
     *                        — the Uniswap reference leaf format. NOT the OZ StandardMerkleTree
     *                        double-hash; the off-chain generator must match exactly (DESIGN.md).
     * @param totalClaimable_ Σ leaf amounts. Claims cannot activate until the vault holds ≥ this
     *                        much v2, so it must fit the v2 supply earmarked as backing. When
     *                        PRO_RATA_ENABLED this MUST equal the flat ratio applied to the NET
     *                        ledger (enforced below; see ProRataTotalMismatch).
     */
    function commitRoot(bytes32 root_, uint256 totalClaimable_) external onlyOwner {
        if (phase != Phase.Open) revert NotOpen();
        if (block.timestamp <= DEPOSIT_DEADLINE) revert DeadlineNotPassed(DEPOSIT_DEADLINE, block.timestamp);
        if (block.timestamp > COMMIT_DEADLINE) revert CommitWindowClosed(COMMIT_DEADLINE, block.timestamp);
        if (root_ == bytes32(0)) revert ZeroAmount();
        if (totalClaimable_ == 0) revert ZeroAmount();
        // Flat-ratio precondition for the proofless path (see PRO_RATA_ENABLED): the committed
        // total must equal the formula applied to the NET ledger (deposits − withdrawals). This
        // binds the allocation's SUM; per-leaf equality is a tree-build process obligation —
        // DESIGN.md "Harvested features" records why that division of labor is the safe one.
        if (PRO_RATA_ENABLED) {
            uint256 expected = ((totalDepositedV1 - totalLedgerWithdrawnV1) * MIGRATION_RATE_BPS) / 10_000;
            if (totalClaimable_ != expected) revert ProRataTotalMismatch(expected, totalClaimable_);
        }

        root = root_;
        totalClaimable = totalClaimable_;
        rootCommittedAt = block.timestamp;
        phase = Phase.Committed;

        emit RootCommitted(root_, totalClaimable_);
    }

    /**
     * @notice Cancel before root commitment and open ledger refunds.
     * @dev After commitment, only claim activation or the execution timeout may resolve the migration.
     */
    function cancel() external onlyOwner {
        if (phase != Phase.Open) revert NotOpen();
        phase = Phase.Cancelled;
        emit MigrationCancelled();
    }

    /**
     * @notice Permissionless pre-commit timeout. If the owner has not committed a root by
     *         COMMIT_DEADLINE, anyone may cancel the migration; every depositor then exits through
     *         the ledger ({withdrawV1} or a relayed {refund}). No signer action is required.
     */
    function expireCommit() external {
        if (phase != Phase.Open) revert NotOpen();
        if (block.timestamp <= COMMIT_DEADLINE) revert CommitWindowStillOpen(COMMIT_DEADLINE, block.timestamp);
        phase = Phase.Cancelled;
        emit CommitExpired();
    }

    /**
     * @notice Permissionless execution timeout. If the operator committed a root but failed to
     *         activate claims within EXECUTION_WINDOW, anyone may open ledger refunds. At that
     *         point the vault still holds ALL deposited v1 — v1 cannot leave before claims
     *         activate — so every refund is fully backed by construction.
     */
    function expireExecution() external {
        if (phase != Phase.Committed) revert NotCommitted();
        // Activation may release v1 for settlement. Keep refunds permanently closed afterwards,
        // including after claim expiry, when the v1 backing may no longer be here.
        if (claimsEverActive) revert ClaimsAlreadyActive();
        uint256 deadline = rootCommittedAt + EXECUTION_WINDOW;
        if (block.timestamp <= deadline) revert ExecutionWindowStillOpen(deadline, block.timestamp);
        phase = Phase.Cancelled;
        emit ExecutionExpired();
    }

    // ---------------------------------------------------------------------------------------------
    // Claims (Committed phase, after activation)
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Activate claims within the execution window, after funding all v2 entitlements.
     * @dev Only then may deposited v1 be withdrawn for settlement; see {withdrawV1ForSettlement}.
     */
    function activateClaims() external onlyOwner {
        if (phase != Phase.Committed) revert NotCommitted();
        if (claimsActive) revert ClaimsAlreadyActive();
        // Expiry is terminal: reopening would reset the claim window and settlement gate.
        if (claimsExpired) revert ClaimsExpiredTerminal();
        // The execution window is a hard deadline for the Safe, not a race: once it has passed, holders' timeout
        // exit (expireExecution) must not be pre-empted by a late launch. Allowed up to and including the
        // deadline; expireExecution opens one second later.
        uint256 deadline = rootCommittedAt + EXECUTION_WINDOW;
        if (block.timestamp > deadline) revert ExecutionWindowEnded(deadline, block.timestamp);

        uint256 backing = V2.balanceOf(address(this));
        if (backing < totalClaimable) revert InsufficientBacking(totalClaimable, backing);

        claimsActive = true;
        claimsEverActive = true;
        claimWindowEnd = CLAIM_PERIOD == 0 ? type(uint256).max : block.timestamp + CLAIM_PERIOD;
        emit ClaimsActivated(backing, claimWindowEnd);
    }

    /**
     * @notice Close the claim window once the published period has run. Permissionless. With
     *         CLAIM_PERIOD == 0 the window never closes, so this always reverts.
     */
    function expireClaims() external {
        if (!claimsActive) revert ClaimsNotActive();
        if (block.timestamp <= claimWindowEnd) revert ClaimWindowStillOpen(claimWindowEnd, block.timestamp);
        claimsActive = false;
        claimsExpired = true;
        emit ClaimsExpired();
    }

    /**
     * @notice Pay a Merkle allocation to its committed `account`, never to the relayer.
     * @dev Claim bookkeeping updates before the token transfer.
     */
    function claim(uint256 index, address account, uint256 amount, bytes32[] calldata proof) external {
        if (!claimsActive) revert ClaimsNotActive();
        if (block.timestamp > claimWindowEnd) revert ClaimWindowEnded(claimWindowEnd, block.timestamp);

        _markClaimed(index);
        if (PRO_RATA_ENABLED) {
            // Shared claim bookkeeping: a formula payout must never precede a root payout for the
            // same account. Set-only (no check) — multi-leaf accounts stay root-claimable.
            if (_claimedViaProRata[account]) revert AlreadyClaimedAccount(account);
            _resolvedViaRoot[account] = true;
        }
        _verifyLeaf(index, account, amount, proof);
        _recordPayout(amount);

        SafeERC20.safeTransfer(V2, account, amount);
        emit ClaimPaid(index, account, amount);
    }

    /**
     * @notice Pay the caller its flat-ratio ledger entitlement without requiring a Merkle proof.
     * @dev Available only with PRO_RATA_ENABLED. The off-chain root must match the ledger formula;
     *      {commitRoot} verifies only its aggregate total. An account cannot use both claim paths,
     *      and both paths count towards totalClaimedAmount and the committed payout cap.
     */
    function claimProRata() external {
        if (!PRO_RATA_ENABLED) revert ProRataDisabled();
        if (!claimsActive) revert ClaimsNotActive();
        if (block.timestamp > claimWindowEnd) revert ClaimWindowEnded(claimWindowEnd, block.timestamp);
        if (_resolvedViaRoot[msg.sender] || _claimedViaProRata[msg.sender]) {
            revert AlreadyClaimedAccount(msg.sender);
        }

        uint256 amount = ((credited[msg.sender] - withdrawn[msg.sender]) * MIGRATION_RATE_BPS) / 10_000;
        if (amount == 0) revert NothingToClaim();

        _claimedViaProRata[msg.sender] = true; // CEI: bookkeeping before transfer
        _recordPayout(amount);
        SafeERC20.safeTransfer(V2, msg.sender, amount);
        emit ProRataClaimed(msg.sender, amount);
    }

    /// @dev Cap both claim paths at the committed total. This also protects excess v2 from a root
    ///      whose leaf amounts sum to more than the total declared by the owner.
    function _recordPayout(uint256 amount) private {
        uint256 remaining = totalClaimable - totalClaimedAmount;
        if (amount > remaining) revert ExceedsTotalClaimable(amount, remaining);
        totalClaimedAmount += amount;
    }

    /// @notice Refund the account's remaining v1 credit when Cancelled. Anyone may relay the call;
    ///         the payout always goes to `account`.
    /// @dev Uses the on-chain ledger, not Merkle allocations, and shares its debit with {withdrawV1}.
    function refund(address account) external {
        if (phase != Phase.Cancelled) revert NotRefundPhase();

        uint256 amount = credited[account] - withdrawn[account];
        if (amount == 0) revert NothingToWithdraw();

        withdrawn[account] += amount;
        totalLedgerWithdrawnV1 += amount;
        SafeERC20.safeTransfer(V1, account, amount);

        emit RefundPaid(account, amount);
        emit WithdrawalReceipt(account, amount, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Settlement support (operator; strictly after claims are live)
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Withdraw v1 to the settlement executor (the operator Safe) for the sale leg.
     *         Requires claims to be ACTIVE — i.e. the v2 side of the bargain is already fully
     *         funded — so the sale can never strand a claimant. This ordering is the contract's
     *         core holder protection; do not relax it without re-reading DESIGN.md.
     */
    function withdrawV1ForSettlement(address to, uint256 amount) external onlyOwner {
        if (!claimsActive) revert ClaimsNotActive();
        if (to == address(0)) revert ZeroAddress();
        SafeERC20.safeTransfer(V1, to, amount);
        emit SettlementWithdrawn(to, amount);
    }

    /**
     * @notice Return v1 that reached the vault WITHOUT a deposit. A plain transfer earns no credit,
     *         so without this it has no way out. Pays only the balance above what the vault owes
     *         depositors in v1 — the whole net ledger until claims activate, nothing after (their
     *         v1 is then settlement inventory) — so no deposit can ever leave this way. The vault
     *         cannot tell who sent the excess; the Safe returns it to the sender.
     */
    function rescueV1(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 owed = claimsEverActive ? 0 : totalDepositedV1 - totalLedgerWithdrawnV1;
        uint256 balance = V1.balanceOf(address(this));
        if (balance <= owed) revert NothingToRescue();
        uint256 excess = balance - owed;
        SafeERC20.safeTransfer(V1, to, excess);
        emit V1Rescued(to, excess);
    }

    // ---------------------------------------------------------------------------------------------
    // Residual sweep
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Sweep v2 that no claimant can still be owed to the owner. Permissionless; always
     *         pays the owner.
     *         - While claims can be made: only the balance above the unpaid entitlements, so
     *           every open entitlement stays fully backed.
     *         - After the claim window closed (CLAIM_PERIOD > 0 only): everything left,
     *           unclaimed entitlements included — the forfeiture such a deployment publishes.
     *         - Cancelled before activation: everything, since claims can never go live there.
     *         Before activation in a live migration nothing moves: the backing may still be
     *         needed to activate.
     */
    function sweepResidual() external {
        uint256 reserved;
        if (claimsEverActive) {
            if (block.timestamp <= claimWindowEnd) {
                reserved = totalClaimable > totalClaimedAmount ? totalClaimable - totalClaimedAmount : 0;
            }
        } else if (phase != Phase.Cancelled) {
            revert ClaimsStillActive();
        }

        uint256 balance = V2.balanceOf(address(this));
        if (balance <= reserved) revert NothingToSweep();
        uint256 residual = balance - reserved;
        SafeERC20.safeTransfer(V2, owner, residual);
        emit Swept(owner, residual);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function availableToWithdraw(address account) external view returns (uint256) {
        return credited[account] - withdrawn[account];
    }

    /**
     * @notice Report claim backing, v1 custody and claim status without changing state.
     * @dev Backing is sufficient only with a committed root and either a closed claim window or
     *      `v2Balance + claimedSoFar >= totalClaimable`. Including paid claims avoids reporting a
     *      shortfall during distribution; expired entitlements no longer require backing.
     */
    function verifySettlement()
        external
        view
        returns (
            bool backingFullyFunded,
            uint256 v2Balance,
            uint256 claimableTotal,
            uint256 v1InCustody,
            bool active,
            uint256 claimedSoFar
        )
    {
        v2Balance = V2.balanceOf(address(this));
        claimableTotal = totalClaimable;
        v1InCustody = V1.balanceOf(address(this));
        active = claimsActive;
        claimedSoFar = totalClaimedAmount;
        bool windowClosed = claimsEverActive && block.timestamp > claimWindowEnd;
        backingFullyFunded = root != bytes32(0) && (windowClosed || v2Balance + claimedSoFar >= claimableTotal);
    }

    function isClaimed(uint256 index) public view returns (bool) {
        // Each storage word holds 32 claim flags. `&` binds tighter than `!=` in Solidity;
        // explicit parentheses make the masked-word comparison clear.
        return (_claimedBitmap[index >> 5] & (2 ** (index & 31))) != 0;
    }

    // ---------------------------------------------------------------------------------------------
    // Two-step ownership transfer
    // ---------------------------------------------------------------------------------------------

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    function _markClaimed(uint256 index) private {
        uint256 bit = 2 ** (index & 31); // Bit position within the 32-claim word.
        if ((_claimedBitmap[index >> 5] & bit) != 0) revert AlreadyClaimed(index);
        _claimedBitmap[index >> 5] |= bit; // state BEFORE transfer (checks-effects-interactions)
    }

    function _verifyLeaf(uint256 index, address account, uint256 amount, bytes32[] calldata proof) private view {
        bytes32 leaf = keccak256(abi.encodePacked(index, account, amount));
        if (!MerkleProof.verify(proof, root, leaf)) revert InvalidProof();
    }
}
