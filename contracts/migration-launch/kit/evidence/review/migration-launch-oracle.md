# §3.5 oracle review: MigrationSettler

- **Diff:** `.review-diffs/settler.patch` on `contracts/migration-launch/src`, from bcf70b7c4 (the faithful port) to
  b62393184. It adds four fixes:
  - **S1:** approvals are bounded and revoked.
  - **S2:** the settler sells exactly the signed `v1In`, seeds what that sale raised, and returns the rest.
  - **S3:** the successor key and its hook are checked.
  - **S4:** the old pool is pinned by id.
- **Result:** 2 findings in round 1, none in round 2.
  - One is real, and **fixed in the commit that follows this report** (see "Fix" under R1-2): the
    successor-hook check now pins the fee hook's fee and treasury.
  - The other (Permit2 expiration 0) is refuted, by Permit2's source and by the fork run.

> **Correction to `SUMMARY.md` (a9d1e0544):** it records "no findings" for the settler. Round 1 found the real
> finding below, and its regressions fail on launch-readiness a9d1e0544 too.

## How it ran

- **Setup:** the same as the other reports (RepoPrompt oracle, review mode, workspace rooted at this worktree).
- **Context (32k tokens):** the diff, the settler, `LaunchInterfaces.sol`, `LaunchMath.sol`, the fork base and suites,
  `HookDouble`, `kit/params.json` and `SurplusFeeHook.sol`.
- **Sanity probes:** round 1 quoted `_checkSuccessor`, round 2 `_revoke`; both exact.

The two rounds asked:

- **Round 1** asked for fund-flow and ordering defects against the real PoolManager, the PositionManager
  (MINT_POSITION, SETTLE_PAIR), Permit2 and v3 semantics:
  - both sale legs;
  - `_size` in both token orientations;
  - the order sell → size → initialize → mint → revoke → return;
  - reentrancy through the callbacks;
  - griefing by a third party;
  - whether S1–S4 are complete.
- **Round 2** excluded round 1's findings and asked specifically about:
  - `_size` rounding against what the PositionManager actually pulls;
  - the sale legs' signs and price limits;
  - `nextTokenId`;
  - donations and a pre-initialized successor key;
  - `settle` called twice;
  - the receipts.

  The answer was "No new findings", with a reason for each area.

## Findings

| # | Oracle rating | Finding | Verdict | Regression (fails on b62393184) | Status |
|---|---|---|---|---|---|
| R1-1 | critical | Permit2 `approve(…, expiration 0)` is already expired, so the mint cannot settle | **not a defect**: refuted | — | — |
| R1-2 | high | `_checkSuccessor` accepts any hook bound to the settler: it checks neither the fee nor the treasury | **real**, medium | `test_ORACLE_settler_AHookWithoutTheFeeIsRefused`, `…AFeeHookPayingAnotherTreasuryIsRefused`, `…AHookDeclaringAnotherFeeIsRefused`, `…AHookThatHidesItsTreasuryIsRefused` | **fixed** on feat/sur-658-launch-readiness (evidence `settler-hook-pin.txt`) |

### R1-1: Permit2 expiration 0 means "this block" (NOT A DEFECT)

The call is at `MigrationSettler.sol:289`. The oracle claimed that Permit2 stores 0 as the expiry, so the
PositionManager's `transferFrom` would revert with `AllowanceExpired(0)`. Permit2's source says otherwise:

- `Allowance.updateAll` stores `expiration == 0 ? uint48(block.timestamp) : expiration`.
- `AllowanceTransfer._transfer` reverts only `if (block.timestamp > allowed.expiration)`.

So 0 means "valid in this block", which is what the comment on `_approve` says.

The fork run confirms it.

- In `test_Launch_V2SortsAboveWeth`, the trace shows `Permit2.approve(token, PositionManager, amount, 0)`. Both
  following `Permit2.transferFrom(settler → PoolManager)` calls succeed.
- Every launch test passes, with the Permit2 runtime code hash-pinned at the fork block.
- The oracle's proposed fix, `uint48(block.timestamp)`, is equivalent to the current code.

This also makes S1 complete: the oracle had marked S1 incomplete only because of this claim.

### R1-2: the settler cannot tell the fee hook from any hook bound to it (REAL)

`MigrationSettler.sol:218-229`. The contract header promises that the settler "can never open a pool without the
1.5% hook". `_checkSuccessor` checks only three things:

- the flag bits are exactly 0x2044;
- the hook has code;
- `INITIALIZER()` names the settler.

It never checks the fee, or who receives it. Both cases below reproduce on the pinned fork. Each runs the real batch's
first four steps, and the control is the real fee hook: the signed params settle.

1. **No fee.** The kit's own rehearsal stand-in, `test/utils/HookStandIn.sol`, has the real hook's constructor and
   initializer gate but charges no fee. Bound to the settler, it passes the check, and `settle` opens and seeds the
   successor pool with no fee. `test_ORACLE_settler_AHookWithoutTheFeeIsRefused` fails with `the settler opened the
   successor pool with a hook that charges no fee`.
2. **Fees to the wrong address.** The real `SurplusFeeHook`, bound to the settler but deployed with a mistyped
   treasury, passes too. Every fee the pool ever charges then accrues to that address, and only that address can
   withdraw it. `test_ORACLE_settler_AFeeHookPayingAnotherTreasuryIsRefused` fails with `the settler opened the
   successor pool with a fee hook whose treasury is not the Safe`.

**Why medium, not high.** It needs a wrong deploy input, and the launch path's own guards against one are off-chain
and partial. Each point below comes from reading the code:

- `deploy_plan.py` substitutes the stand-in only under `--rehearsal`, but it uses an explicit `--hook-artifact` as
  given (`:56-60`).
- `DeployDryRun._checkHook` checks the flags, `INITIALIZER` and `POOL_MANAGER`, but not the treasury or the fee
  (`script/DeployDryRun.s.sol:204-209`).
- The treasury comes from `hook.feeRecipient`, which is still TBD (§6.4).

On the other hand, nothing on chain catches it, and the result is permanent. A pool's hook is fixed when the pool is
initialized, and the hook's treasury is immutable.

**Fix (applied on feat/sur-658-launch-readiness; evidence `settler-hook-pin.txt`):**

- `_checkSuccessor` reads the hook's own immutables back, each behind the same try/catch as `INITIALIZER()`:
  - `TREASURY() == FEE_RECIPIENT`, a new settler immutable. The kit passes the same `hook.feeRecipient` to both
    constructors. It is not hardcoded to the Safe, because the recipient is still an open decision (§6.4).
  - `FEE_PIPS() == HOOK_FEE_PIPS` (15,000, i.e. 1.5%).
- The oracle suggested pinning the hook's address or code hash in the settler's `Config` instead. That is circular:
  the hook's constructor takes the settler's address (`INITIALIZER`), so the hook's CREATE2 address and its runtime
  code both depend on the settler.
- **Tests:** four regressions fail on the unfixed settler and pass after:
  - no fee (the kit's fee-less stand-in);
  - the real hook with the wrong treasury;
  - a hook declaring a different fee;
  - a hook with no treasury getter.
- **Mutants:** each of the four guards removed alone turns a named test red.
- **Kit changes:**
  - `DeployPlan` passes `feeRecipient` to the settler.
  - `DeployDryRun` checks the settler's `FEE_RECIPIENT` and the hook's `TREASURY` and `FEE_PIPS`. A plan with a
    mismatched recipient fails with `settler: fee recipient`.
  - `deploy_plan.py` no longer falls back to the stand-in: the fixed settler would refuse it.
- **Test double:** the fork suites' `HookDouble` answers the same getters as the real hook.
- **Consequence:** the settler and hook addresses move; the Safe, token and vault do not.
- **Full-scale rehearsal:** re-run with the new pair on the already-deposited private fork. The snapshot root is
  unchanged (0x7032…79d4) and the rehearsal passes 7/7.

## Also measured here: the hook's exact-output take on the launched pool

`HookExactOutputThresholdForkTest` is in the same file but belongs to the fee-hook review (R2-1 in
`fee-hook-oracle.md`). It lives here because it needs the real launch batch.

## The diff's own fixes

- **S1:** complete. The oracle's "incomplete" rested on R1-1, which is refuted.
- **S2:** complete.
- **S4:** complete. The callbacks are reachable only through the pinned venues.
- **S3:** incomplete as reviewed. It pinned the key's currencies, fee, spacing, flags and initializer, but not the
  hook's fee or treasury (R1-2, now fixed).
- **Tests:** `SettlerRegressions.fork.t.sol` (S1–S4) and the launch suite pass at b62393184, 15/15.

## Open questions

The oracle raised none.
