# §3.5 oracle review: MigrationVault

- **Diff:** `aeab69988..b62393184` on `contracts/migration`. This is the P1–P7 launch hardening: the ledger
  freeze and `COMMIT_DEADLINE`, ledger refunds, `rescueV1`, and the `claimPeriod` parameter.
- **Reviewed at:** b62393184, branch `feat/sur-658-oracle-review`.
- **Result:** 3 findings, all reproduced as real, all **fixed by the parent in 189de9038** on
  `feat/sur-658-launch-readiness`. The oracle raised no false positives on this contract.

## How it ran

- **Tool:** RepoPrompt oracle (preset CLI·GPT-5.5 High) in review mode.
- **Workspace:** rooted at this worktree, so the oracle read the reviewed branch, not the main checkout.
- **Context (49k tokens):** the diff, the full `MigrationVault.sol`, `DESIGN.md`, `README.md`, the P-regressions and
  the invariant suite.
- **Sanity probe:** each run first had the oracle quote a function verbatim. The quote was compared byte for byte
  with the worktree before any finding was read. Round 1 quoted `expireCommit`, round 2 `rescueV1`; both exact.

The two rounds asked different questions:

- **Round 1** listed Bill's fixed decisions: 1:1, pro-rata on, pool first in one Safe batch, push distribution, root
  from deposits, Base, and `claimPeriod` still open. It asked for defects in fund flows, access control, ordering and
  griefing, and whether each P-fix is complete.
- **Round 2** excluded round 1's finding and asked specifically about:
  - time boundaries;
  - deploy-parameter edge cases;
  - how sweep, rescue and settlement interact in both `claimPeriod` modes;
  - claim and pro-rata bookkeeping under a Multicall3 push;
  - over-payment;
  - receipt events.

Run ids and outputs: `oracle-review-runs.txt` §1 and §3.

## Findings

| # | Oracle rating | Finding | Verdict | Regression (fails on b62393184) | Status |
|---|---|---|---|---|---|
| R1-1 | high | `activateClaims` still works after the execution deadline | **real** | `test_ORACLE_migration_ActivationAfterTheExecutionDeadline` | fixed by the parent, 189de9038 |
| R2-1 | medium | a claim can pay past `totalClaimable` | **real, low** | `test_ORACLE_migration_PayoutsNeverExceedTheCommittedTotal` | fixed by the parent, 189de9038 |
| R2-2 | medium | deadline arithmetic can overflow and brick the vault | **real** (deploy-time) | `test_ORACLE_migration_ClaimPeriodThatOverflowsBricksActivation`, `test_ORACLE_migration_ExecutionWindowThatOverflowsIsRejected` | fixed by the parent, 189de9038 |

The four regressions live in `contracts/migration/test/regressions/OracleReview.t.sol`, which the parent owns and
which is not part of this branch's commit:

- The parent copied this review's two tests verbatim: the activation deadline and the `claimPeriod` overflow.
- It added two of its own: the payout cap and the `executionWindow` overflow.
- Run here, all four **fail on the reviewed vault** (b62393184) and pass on launch-readiness a9d1e0544, where the
  migration suite is 118/118.

### R1-1: the execution window was a race, not a deadline

`MigrationVault.sol:406` (`activateClaims`) never checked `rootCommittedAt + EXECUTION_WINDOW`. Past that deadline
`expireExecution` becomes callable. Until someone actually calls it, though, the Safe can still activate claims and
then withdraw the v1 for settlement. So the published rule, "no activation within the window, then anyone may open
refunds", is a mempool race.

- **Reproduced:** deposits, commit and backing, then a `warp` to the deadline + 1 second. `activateClaims` succeeds.
  The test asserts that it must not, and that both holders then exit through `expireExecution` and `refund`.
- **Harm (bounded):** activation still requires full v2 backing, so a late activation hands holders fully backed v2 at
  1:1, not a loss. What breaks is the promised exit: a holder who is waiting for the timeout refund can be migrated
  anyway.
- **Collateral:** `E2EMultisig.t.sol` activated 1 second after the window, so it had pinned the defect.
  - Adding the deadline check in a scratch copy turned that test red (`MiniSafe: exec reverted`), and no other test.
  - 189de9038 moves the test's activation to the deadline itself.
- **Fix (parent):** activation reverts with `ExecutionWindowEnded` after the deadline. It is allowed up to and
  including the deadline, and `expireExecution` opens one second later.

### R2-1: payouts were not capped at the committed total

`claim` (`:440`) and `claimProRata` (`:474`) add to `totalClaimedAmount` without comparing it to `totalClaimable`.
`commitRoot` binds only the declared total (under pro-rata, to the net ledger). It never binds the leaves behind the
root. Suppose a root's leaves sum to more than the total, and the vault holds v2 beyond the backing (over-funding or
a donation). Then the leaf holders are paid that excess.

- **Reproduced:** the parent's regression, run here on b62393184, fails with `a leaf outside the committed total was
  paid`.
- **Why low:** it needs two things.
  - A malformed root. The kit's snapshot phase checks the leaves three independent ways before the Safe signs.
  - v2 in the vault beyond the backing.
- **Fix (parent):** `_recordPayout` reverts with `ExceedsTotalClaimable`, and the invariant suites assert the cap.
  This is defense in depth.

### R2-2: deadline arithmetic could overflow

The constructor (`:225`) accepted any `executionWindow` and any `claimPeriod`. Two functions add them to a timestamp:

- `activateClaims` computes `block.timestamp + CLAIM_PERIOD` (`:419`);
- `expireExecution` computes `rootCommittedAt + EXECUTION_WINDOW` (`:390`).

With a value near `type(uint256).max`, the vault deploys, takes deposits and commits, then panics (0x11) forever.
Either the migration can never go live, or the timeout exit never opens.

- **Reproduced:** with `claimPeriod = type(uint256).max`, deposit, commit and backing all succeed. Then
  `activateClaims` reverts with `panic: arithmetic underflow or overflow (0x11)`. The test accepts either fix shape:
  reject the value at deployment, or activate.
- **Scope:** this is a guard on deploy parameters.
  - The launch values are day-scale.
  - `claimPeriodSeconds` has since been decided as 0 (Bill, 2026-09-29).
  - `executionWindowSeconds` is still TBD (§6.3).
- **Fix (parent):** the constructor reverts with `WindowTooLong` when either sum could overflow.

## The diff's own fixes

- **Oracle verdicts:** P1/P1b/P2/P7, P3, P4 and P6 complete. P5 "mostly complete"; its only reservation was R1-1.
- **Regressions:** each fix already has one under `test/regressions/` (`LedgerFreeze`, `LedgerRefunds`, `ClaimExpiry`,
  `PlainTransferRescue`). The full suite passes at b62393184: 114/114.
- **Push distribution:** the oracle judged the claim/pro-rata bookkeeping complete for one leaf per depositor at 1:1.
  The relayer and the holder can each resolve an account at most once, and a relayer cannot redirect a payout.

## Open questions the oracle raised

- **`claimPeriod` policy:** decided since the review. Claims never expire (`claimPeriodSeconds` 0, Bill 2026-09-29,
  recorded in 38c25b24a).
- **Sizing `COMMIT_DEADLINE` and `EXECUTION_WINDOW`** against Safe signing latency: still an open §6.3 decision. After
  R1-1's fix the execution window is a hard deadline for the Safe, so it must leave room to sign the whole launch
  batch.
