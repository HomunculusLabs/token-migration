# DESIGN.md — MigrationVault

**Status:** draft for review (SUR-658). Grounded in the SURPLUS migration design dossier (REV 01,
23 SEP 2026, `SURPLUS_migration_blueprint.html`) and the Anvil fork evidence report
(`SURPLUS_anvil_lab_full_report.md`, SHA-256 `dd49b65f…da7bda`, pinned Base block 51702954).

This document records what the contract enforces, what it deliberately does not, and every
decision that was taken or deferred. Nothing here is deployed; production deployment is out of
scope for SUR-658.

## 1. What this contract is

`MigrationVault` is the custody + deposit-ledger + claims half of the token migration. Holders
deposit old SURPLUS (v1) during an open window; the vault credits them, never trades the deposits
while the window is open, and resolves in exactly one of two ways:

- **Happy path** — window closes → allocation root committed → operator posts full v2 backing →
  claims activate → holders claim v2 against Merkle proofs; the v1 is then released to the
  operator for the settlement leg (sale + successor LP).
- **Failure path** — owner cancellation before commitment, the pre-commit timeout (no root by
  `COMMIT_DEADLINE`), or the execution timeout after commitment. Every path gives each depositor
  back exactly their net ledger credit in v1, by their own `withdrawV1` or by anyone's relayed
  `refund(account)`. **No signer action is required.**

This is the dossier's architecture **"D · Escrow + Merkle"** (§02), with the settlement leg
deliberately left OFF-chain (see §6).

## 2. The ordering rule (the contract's core protection)

> v1 may leave the vault for settlement **only after** claims are activated, and claims activate
> only when the vault holds v2 ≥ `totalClaimable`.

Consequence: a vanished or malicious-after-commitment operator leaves holders in exactly one of
two states — (a) untouched v1 fully refundable via the permissionless timeout, or (b) fully funded
live v2 claims. The dossier's failure §07-13 ("sale succeeds but claim funding fails — depositors
hold a promise instead of funded rights") is impossible **by construction**, not by disclosure.

## 3. Phase machine

```
        deposit / withdrawV1 until           commitRoot (owner, after the deposit deadline,
        the deposit deadline                  by COMMIT_DEADLINE)
Open ────────────────────────────────► Committed ────────────────────────────┐
  │                                                                      │ activateClaims (owner,
  │ cancel (owner), or expireCommit                                      │   requires v2 ≥ totalClaimable)
  │ (anyone, after COMMIT_DEADLINE)                                      │
  ▼                                                                      ▼
Cancelled ◄──────────────────────────────────────────────────────  claimsActive
  (ledger exits: withdrawV1 pull,                               claim() ──► expireClaims()
   or anyone's relayed                                           (window enforced in claim() itself)
   refund(account) push)                                         sweepResidual(): only v2 no claimant
                                                                 can still be owed (§11 P5)
```

- The ledger freezes at `DEPOSIT_DEADLINE`: no deposit and no `withdrawV1` after it while the
  vault is Open, and none while Committed. The root is built from the ledger as of the deadline,
  so the ledger must not move between the snapshot and `commitRoot` (§11 P1/P1b/P2).
- `Open` → `Committed` is the point of no return (`RootCommitted`), allowed only between the
  deposit deadline and `COMMIT_DEADLINE`.
- `Open` → `Cancelled` (via the owner's `cancel`, or anyone's `expireCommit` once
  `COMMIT_DEADLINE` has passed with no root), and `Committed` → `Cancelled` (via permissionless
  `expireExecution` after `EXECUTION_WINDOW` with no activation): every depositor
  exits through the ledger — `withdrawV1` (pull) or `refund(account)` (anyone may push it; it pays
  the account). Both draw on the same `credited − withdrawn` balance, so nobody is paid twice
  whichever path they use. The root plays no part in refunds (§11 P3). Refunds are fully backed
  because v1 cannot have left before activation (ordering rule). A post-commitment owner `cancel`
  does not exist — that is the dossier's "do not silently weaken the offer after accepting
  deposits" rule made structural.

## 4. Merkle claims

- **Leaf format:** `keccak256(abi.encodePacked(index, account, amount))` — the **Uniswap reference
  distributor** format (dossier §04 "choose a matching tree and verifier"). NOT the OZ
  StandardMerkleTree double-hash `keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))))`.
  The off-chain generator (tree build scripts, future PR) must match this exactly; `test/TestMerkle.sol`
  is an INDEPENDENT implementation used by the suite, so generator drift fails tests.
- **Verifier:** OpenZeppelin `MerkleProof.verify` (npm-pinned 4.9.6), sorted-pair nodes.
- **Indices are globally unique** across the tree; the 32-per-word bitmap prevents reuse within
  this vault. A correction after launch requires a separately funded, non-overlapping process —
  the dossier's §07-09 rule. There is no root update path on purpose.
- **Fixed beneficiary:** `claim(index, account, amount, proof)` pays `account` from the leaf, never
  the caller — relayers can pay gas but cannot redirect payouts (dossier §07-17). State (bitmap)
  is updated BEFORE the transfer (CEI).
- **Binding to deployment:** the leaf does not encode chainId or the vault address; the manifest
  (deployment runbook) pins the deployment, and proofs must not be reused against another
  distributor (dossier §04 warning).

## 5. Ledger rules (what credits an allocation)

Encoded on-chain:

- Credit = `transferFrom`'s `from` (the caller of `deposit` moving their own tokens) — the
  dossier's "credit `Transfer.from`, never the tx sender" rule holds because `deposit` requires
  allowance from the credited party. Contract wallets qualify by construction.
- Repeated deposits aggregate per account. Zero-amount deposits revert.
- Window boundaries are inclusive-exclusive as documented on the functions.

Left to the OFF-chain ledger build (dossier §04 ledger acceptance rules — these cannot be encoded
in this vault because deposits are ordinary ERC-20 transfers, not bespoke events):

- Intermediary/exchange deposits (an exchange's customers' funds arrive attributed to the
  exchange): predeclared exception path reviewed before root freeze.
- Refund reversals and beneficiary corrections: recorded in `exceptions.csv`, applied at tree
  build; on-chain `withdrawV1` before commitment is the sanctioned reversal path.
- Late transfers after cutoff: outside the tree; separately funded policy only.

## 6. What is deliberately NOT in this contract

1. **The settlement leg** (selling v1, funding the successor LP, runways) — operator Safe actions
   against `withdrawV1ForSettlement`'s output. The dossier's §05 settlement postconditions (route
   pinning, LP checks, mandatory-failure revert semantics) belong to that executor's review, not
   to custody. Rationale: encoding the sale on-chain would make the vault the router, multiplying
   the review surface (hook interaction, slippage, partial fills) exactly as the dossier's
   "minimal custody-code direction" argues against.
2. **Fees** — no deposit/claim fee in v1. If the economics need one, it is a follow-up change with
   its own review; the authority table stays minimal.
3. **Vesting / migrator bonus** — dossier §05: a bonus that vests is a SEPARATE funded
   implementation; a plain Merkle payout cannot vest. If a bonus is decided, it becomes a second
   leaf class or a second contract — never a hidden lock inside base claims.
4. **Upgradeability / admin generic calls** — none. The vault is immutable except the two-step
   ownership transfer (for custody-handover rehearsal, SUR-662). Owner powers are exactly:
   `commitRoot`, `cancel` (pre-commitment), `activateClaims`, `withdrawV1ForSettlement`,
   `rescueV1` (excess above the ledger only), `transferOwnership`.
5. **Sweep of claimable entitlements** — impossible: while a claim can still be made,
   `sweepResidual` takes only the v2 above the unpaid entitlements, so every open entitlement
   stays fully backed (dossier §04 claim invariant / §07-16). Unclaimed v2 leaves only after an
   expiring claim window has closed — and only in a deployment that published that expiry
   (§11 P5).

## 7. Authority table

| Power | Holder | Constraint |
|---|---|---|
| `commitRoot(root, total)` | owner (multisig) | only from Open, after the deposit deadline and by `COMMIT_DEADLINE` |
| `cancel()` | owner | only before commitment |
| `activateClaims()` | owner | only with v2 backing ≥ totalClaimable |
| `withdrawV1ForSettlement(to, amt)` | owner | only after claims active |
| `rescueV1(to)` | owner | only the v1 balance above the net ledger (all of it once claims have activated) |
| `transferOwnership` / `acceptOwnership` | owner → pendingOwner | two-step |
| `deposit` / `withdrawV1` | any holder | Open, up to the deposit deadline (+ `withdrawV1` once Cancelled) |
| `claim` | anyone (pays the leaf's account) | proof; claim-window gate |
| `refund(account)` | anyone (pays the account its net ledger credit) | Cancelled only |
| `claimProRata` | any credited holder (pays caller) | flat-ratio deployments only; post-activation, in-window; mutually exclusive with root paths per account |
| `expireCommit` / `expireExecution` / `expireClaims` / `sweepResidual` | anyone | time/phase gates |

The owner is expected to be the SUR-662 multisig. Every row above is exercised by a test.

## 8. Parameters (deployment decisions — OPEN)

| Parameter | Draft | Decision owner |
|---|---|---|
| `depositDeadline` | TBD (offer window, e.g. 14–30d after launch) | Bill/Mac |
| `commitDeadline` | TBD (absolute; must be after `depositDeadline`; rehearsal: deadline + 3d, time to build and verify the tree and collect signatures) | Bill/Mac |
| `executionWindow` | draft 7d (must outlive realistic Safe signing latency) | Bill/Mac |
| `claimPeriod` | **DECIDED (P5, §11): `0`, claims never expire.** (`N` seconds would expire claims N after activation and let the unclaimed remainder be swept to the Safe.) | ~~Bill~~ Bill, 2026-09-29 |
| v2 token | SUR-661 deliverable (upgradeable ERC-20; mint authority = multisig) | SUR-661 |
| canonical chain | **DECIDED (2026-09-24, Bill): Base.** The vault, v1 custody, and claims all live on Base. Bridging (if any) is SUR-663's OFT question, out of scope here | ~~Bill/Mac~~ resolved |
| migration ratio | **DECIDED (2026-09-28, Bill): 1:1 for every holder.** Flat, so deploy with `PRO_RATA_ENABLED = true` (§10.1) | ~~Bill/Mac~~ resolved |
| launch order | **DECIDED (2026-09-28, Bill): successor pool first, then distribution.** `withdrawV1ForSettlement` requires active claims, so `activateClaims`, the v1 sale and the pool launch execute in ONE Safe transaction — no holder can hold v2 before the pool exists | ~~Bill/Mac~~ resolved |
| late-arrival policy | undecided (dossier §03: separately funded, never root growth) | Bill/Mac |

## 9. Known limitations / not yet done (honest list)

- **Internal audit complete (2026-10-04); external review still open.** Gates, fuzz and two
  oracle review rounds are green at head `c1092a39f` (report:
  `docs/audits/token-migration-full-audit-2026-10-04.md`); the dossier's §08 checklist still
  demands an independent external contract/security review before mainnet launch — tracked, not
  discharged.
- ~~No deployment scripts yet~~ **Discharged** — the launch kit (`kit/` in migration-launch:
  deploy plan, snapshot → tree, safe-txs, push plan, rehearsal gate, check) covers deploy,
  signing simulation and address publication end to end.
- ~~No invariant/fuzz suite yet~~ **Discharged** — handler-based invariant suites with
  ghost-sum conservation accounting (`MigrationVaultInvariant.t.sol`), 20,000-run deep-fuzz
  campaign across all four projects (evidence: `kit/evidence/static-analysis/deep-fuzz-report.md`).
- ~~Tree build tooling~~ **Discharged** — `kit/snapshot.py` (on-chain ledger → deposits.csv →
  tree.json with Σ-reconciliation against the vault's net ledger); the leaf format here matches
  `ClaimTree.leaf` and the vault's `_verifyLeaf`, pinned by `TreeParity.t.sol` against the real
  vault.
- `claim` after window end reverts (`ClaimWindowEnded`) even before `expireClaims` is called — the
  window is enforced in the claim path itself, so liveness of the permissionless closer is not
  load-bearing for correctness.
- The vault does not and cannot verify that the ROOT's contents are fair (a valid proof encodes
  whatever list was committed). That assurance comes from the dossier's §04 review process:
  independent rebuilds, published allocation files, correction window before freeze.

## 10. Harvested features (2026-09-24)

The five-candidate menu (`SURPLUS_migration_contract_candidates.md`) recommended "Vault v1" as
C4 plus three harvests. All three are in; the fourth recommendation (C1's funded-at-launch
discipline) was already structural — `activateClaims` requires full backing in the same
transaction it flips the flag, so there is no pre-funding window by construction.

### 10.1 Proofless flat-ratio claim fallback (from candidate C3)

`claimProRata()` — callable by any holder with net ledger credit, post-activation and in-window.
Pays `(credited − withdrawn) × MIGRATION_RATE_BPS / 10_000` v2 with NO Merkle data: no proof, no
index, no website. This is C3's answer to dossier §07-10 (a claims website outage cannot strand
anyone) and it deletes the proof-data durability duty for every holder who uses it.

**Enabling precondition (the load-bearing one).** `PRO_RATA_ENABLED` is an immutable constructor
flag; when true, `commitRoot` REJECTS any `totalClaimable` that does not equal
`(totalDepositedV1 − totalLedgerWithdrawnV1) × MIGRATION_RATE_BPS / 10_000` (`ProRataTotalMismatch`).
So the proofless path exists only when the ratified allocation IS the flat ratio over the net
ledger. Where any leaf could differ from the formula — per-holder adjustments, bonuses, rounding
bumps, deliberately excluded accounts — the deployment uses `PRO_RATA_ENABLED = false` and the
root path stays the single authority. The brief's `min(formula, remaining)` alternative was
rejected: it re-imports proof data into the "proofless" path (you must know the leaf to compute
the cap), so it is neither simpler nor proofless. The sum-equality check binds what the vault can
verify without leaves; per-leaf equality (one leaf per account, amount = formula) is a tree-build
process obligation enforced by the §4 review process (independent rebuild + published allocation
files), because a contract cannot hash-check leaves it never sees. The two floors agree by
construction: both are `floor(credit × rate / 10_000)` — per-account rounding down is
conservative for the total (Σ floor ≤ floor Σ), so the committed total check can only ever be
satisfied by an allocation the formula path fully funds.

**Shared claim bookkeeping — either path pays an account at most once.** Two private mappings
(zero gas when the flag is false): `_resolvedViaRoot` (set by `claim`) and `_claimedViaProRata`
(set by `claimProRata`). `claimProRata` checks both and reverts `AlreadyClaimedAccount`; `claim`
checks `_claimedViaProRata`. The root-side mapping is deliberately SET-ONLY: an account may
legitimately appear in multiple leaves (split allocations), and marking on first root claim must
not break later leaf claims for that account — the per-index bitmap remains the root path's own
replay guard. Refunds need neither mapping: they pay the ledger, and `expireExecution` reverts
once claims have ever been active (the F1 latch), so no refund can follow any claim. Both claim
paths credit `totalClaimedAmount`, so the all-claimed sweep gate composes across them.

### 10.2 Settlement verification view (from candidate C5)

`verifySettlement() view returns (backingFullyFunded, v2Balance, totalClaimable, v1InCustody,
claimsActive, claimedSoFar)` — pure reporting, no state change. C5's atomic on-chain settlement
was rejected (route brittleness, review surface — see the candidate doc's own verdict); its
harvest is the post-batch checklist as a view any watcher can call: the Discord alarm, the
community, the operator's runbook.

`backingFullyFunded = root committed && v2Balance + claimedSoFar ≥ totalClaimable`. Counting
already-paid claims keeps the flag honest mid-window: after 600k of 1.1M is claimed the vault
holds 500k v2 and the raw-balance reading would falsely alarm. Before commitment it is false —
there is no settlement to verify yet. Note the flag is informational: `activateClaims` enforced
full funding at activation and the vault holds no v2-exit path other than claims/sweep, so a
false reading after activation means tokens left via an unauthorized transfer — which is exactly
what the watcher alarming on this view is for.

### 10.3 Deposit receipt reconciliation events (from candidate C2)

`DepositReceipt(account indexed, netCredited, cumulativeCredited)` from `deposit()` and
`WithdrawalReceipt(account indexed, amount, cumulativeCredited)` from `withdrawV1`. The
cumulatives are the account's NET ledger credit (`credited − withdrawn`) after the event's
mutation — the statement-balance pattern: an indexer's per-account running net must reproduce
every emitted cumulative, making silent indexer drift a mechanical diff instead of a launch
incident. The legacy `DepositIssued`/`LedgerWithdrawn` events are unchanged (their
`totalCredited` stays the GROSS credit) so existing consumers see no drift; the receipt pair
carries the net so a deposit after a withdrawal shows gross 110 vs net 70 side by side — pinned
by `test_ReceiptsCarryCumulativesAcrossSequence`.

## 11. Launch hardening (review findings, 2026-09-28)

The launch review (`review-probe-0928`) found seven defects, P1–P7. Each has a regression test
under `test/regressions/` that failed on the reviewed contract and passes on this one.

- **P1, P1b, P2, P7 — one fix.** Ledger withdrawals stayed open between the deposit deadline and
  `commitRoot`. A holder could be in the root AND have their v1 back (P1); on the timeout path the
  early withdrawer was paid twice and the last depositor got nothing (P1b); with pro-rata on, a
  1-wei withdrawal in front of the Safe's `commitRoot` bricked it, because the total no longer
  matched (P2). The ledger now freezes at `DEPOSIT_DEADLINE`. Freezing alone would trap every
  deposit behind a Safe that never commits, and there was no permissionless pre-commit timeout
  (P7), so the vault takes an absolute `COMMIT_DEADLINE`: `commitRoot` is refused after it, and
  anyone may then call `expireCommit()` to cancel, after which every depositor is refunded from
  the ledger. Pinned by `LedgerFreeze.t.sol` and the invariant `detectorWithdrawAfterDeadline`.

- **P3 — timeout refunds were paid from the root.** `refund(index, account, amount, proof)` paid
  the leaf amount in v1. A wrong root plus an idle execution window handed every deposit to
  whoever the root named. Refunds now pay the on-chain ledger: `refund(account)` returns the
  account's `credited − withdrawn`, and the root has no say. Pinned by
  `LedgerRefunds.t.sol:test_P3_TimeoutRefundsPayTheLedgerNotTheRoot`.
- **P4 — non-1:1 roots turned refunds into a bank run.** Root-paid refunds at, say, 1.1:1 paid
  110 v1 per 100 deposited until the vault ran dry. With ledger refunds any ratio refunds exactly
  each deposit (`test_P4_BonusRootCannotTurnRefundsIntoABankRun`). The launch ratio is 1:1
  (§8), deployed with `PRO_RATA_ENABLED = true` and `MIGRATION_RATE_BPS = 10_000`, so
  `commitRoot` rejects any root whose total differs from the net ledger (`ProRataTotalMismatch`).
  That check binds the SUM; per-leaf equality is a tree-build obligation, verified three
  independent ways by the launch kit before the Safe signs.
- **P6 — v1 sent by plain transfer had no way out.** A plain transfer earns no credit, so the
  most common holder mistake stranded the tokens. `rescueV1(to)` (owner-only) pays out the v1
  balance above what the vault owes depositors: the whole net ledger until claims activate,
  nothing after, because deposited v1 is then settlement inventory that the owner can already
  withdraw. No deposit can leave this way in any phase. The vault cannot tell who sent the
  excess, so the Safe returns it to the sender. Pinned by `PlainTransferRescue.t.sol`.
- **P5 — claim expiry froze unclaimed v2 and leftover v1 forever.** After `expireClaims`,
  `sweepResidual` needed every entitlement claimed, and `withdrawV1ForSettlement` needed claims
  active, so any straggler's v2 and any unsold v1 were stuck for good. The policy is now the
  deploy parameter `claimPeriod`, and nothing is frozen under either value:
  - `claimPeriod == 0` — claims never expire (`claimWindowEnd = type(uint256).max`,
    `expireClaims` always reverts). A holder can claim years later. `sweepResidual` only ever
    takes the v2 above the unpaid entitlements. Leftover v1 stays reachable through
    `withdrawV1ForSettlement` because claims stay active.
  - `claimPeriod > 0` — claims expire that long after activation. Once the window has closed,
    `sweepResidual` sends everything left, unclaimed entitlements included, to the owner, and
    `rescueV1` recovers leftover v1 (after activation no v1 is owed to anyone).
  - Backing posted to a vault that then times out, or is cancelled, before activation is nobody's
    entitlement, so `sweepResidual` returns it to the owner in either mode.

  Bill decided on 2026-09-29 (spec §6 item 5): `claimPeriod = 0`, claims never expire. The expiry mode
  stays tested so the choice remains a parameter. Pinned by `ClaimExpiry.t.sol` and by
  both invariant suites (`MigrationVaultInvariantTest` with expiry,
  `MigrationVaultNoExpiryInvariantTest` without), including
  `invariant_OpenEntitlementsStayBacked`.

## 12. Oracle review (spec §3.5, 2026-09-29)

A RepoPrompt oracle review of this diff found three more defects. Each has a regression in
`test/regressions/OracleReview.t.sol` that failed on the reviewed contract and passes on this one.

- **The execution window was a race, not a deadline.** `activateClaims` had no time limit, so after
  `rootCommittedAt + EXECUTION_WINDOW` a late launch batch could still activate before anyone called
  `expireExecution`, pre-empting every holder's timeout exit. Activation now reverts after the deadline
  (`ExecutionWindowEnded`). It is allowed up to and including the deadline, and `expireExecution` opens
  one second later.
- **Payouts were not capped at the committed total.** `commitRoot` checks only the total the Safe
  declares, not the leaves behind the root. A malformed root whose leaves sum past `totalClaimable`, in a
  vault holding v2 beyond the backing, paid v2 nobody was promised. Both claim paths now stop at
  `totalClaimable` (`ExceedsTotalClaimable`), and the invariant suites assert
  `totalClaimedAmount ≤ totalClaimable`. Honest roots are unaffected: their leaves sum to exactly the total.
- **Deadline arithmetic could overflow.** An `executionWindow` or `claimPeriod` large enough that
  `commitDeadline + executionWindow (+ claimPeriod)` overflows would deploy, take deposits and then panic
  in `expireExecution` or `activateClaims` forever. The constructor rejects such windows (`WindowTooLong`).

