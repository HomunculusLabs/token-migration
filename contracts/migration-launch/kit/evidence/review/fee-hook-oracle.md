# §3.5 oracle review: SurplusFeeHook

- **Diff:** the rehearsal draft (`SURPLUS_migration_rehearsal/src/SurplusFeeHook.sol`) to
  `contracts/fee-hook/src/SurplusFeeHook.sol` at b62393184. It adds:
  - **H1:** the fee is charged in the swap's unspecified currency.
  - **H3:** only the initializer can create a pool, and only the official key; the flag bits must be exactly 0x2044.
  - **H2/H4:** `take()` without `sync()`, and checked transfers.
- **Result:** round 1 found nothing. Round 2 raised two findings:
  - one is real (low) and **fixed by the parent in 1ed281150**;
  - the other is a real mechanism that the launched pool cannot reach, so **not a defect**. The threshold is measured
    on the fork below.

## How it ran

- **Setup:** the same as the other three reports (RepoPrompt oracle, review mode, workspace rooted at this worktree).
- **Context (31k tokens):** the diff, `SurplusFeeHook.sol`, `V4Minimal.sol`, `DESIGN.md`, `README.md`, and the unit,
  regression and fork suites.
- **Sanity probes:** round 1 quoted `REQUIRED_FLAGS`, round 2 `_transfer`; both exact.

The two rounds asked:

- **Round 1**, checked against v4-core 1.0.x semantics:
  - fee math and rounding in all four swap shapes;
  - the team/buyback split accounting;
  - whether `take()` can fail on a legitimate swap;
  - anything that could brick the launch batch's `initialize`;
  - stranded tokens.
- **Round 2**, deeper:
  - whether `take()` fails on exact-output swaps, whose input has not been paid in yet;
  - tokens sent to the hook outside `afterSwap`;
  - rounding and the balance invariant;
  - router paths;
  - the gate against the launch path;
  - any way to move fees other than through the treasury.

## Findings

| # | Oracle rating | Finding | Verdict | Test | Status |
|---|---|---|---|---|---|
| R2-1 | high | exact-output swaps take the fee before the input arrives | **not a defect at launch**: the take fails only in a single swap draining ≥ 98.5178% of the pool's WETH, which would pay in 12.8× all v2 in existence | `HookExactOutputThresholdForkTest` (passes; pins the premise) | known limitation, recorded |
| R2-2 | low | tokens sent to the hook outside a swap are stranded | **real, low** | `test_ORACLE_hook_StrayTokensAreRecoverable` in `test/HookStrayTokenRecovery.t.sol` (fails on b62393184) | fixed by the parent, 1ed281150 |

### R2-1: the exact-output take (NOT A DEFECT at launch)

The call is at `SurplusFeeHook.sol:128`. On an exact-output swap, the fee currency is the swap's input. `afterSwap`
takes the fee from the PoolManager before the swapper has paid any of that input in. So the take needs the manager
to already hold at least 1.5% of the swap's input, in that currency.

**The mechanism is real.** A scratch probe (not committed) builds a deliberately thin pool: a tiny full-range
position, so the manager holds only 158.1 v2, plus deep WETH-only liquidity above the price.

- On that pool, a 1 WETH exact-output sell reverts in `v2.transfer` ← `PoolManager.take` ← `hook.afterSwap`.
- A hookless twin with the same liquidity fills the same sell.
- The same hooked pool fills the sell when it is expressed as exact-input, because then the fee is WETH.
- Output: `oracle-review-runs.txt` §5.

**It is not reachable on the pool the launch opens.** `HookExactOutputThresholdForkTest` is in
`contracts/migration-launch/test/fork/OracleReviewLaunch.fork.t.sol`.

- It runs the real launch batch on the pinned fork, through the real hook and the real v2 proxy.
- It then bisects the exact-output size between "fills" and "the hook's take fails".
- The probe pays nothing: its unlock callback reverts as soon as `swap()` returns.
- Each failure is attributed from the wrapped revert: the `afterSwap` selector, `HookCallFailed` and
  `ERC20TransferFailed`.
- Both currency orders give the same thresholds:

| Swap | Pool reserve of the output | Largest that fills | Smallest whose take fails | Input the swapper would owe |
|---|---|---|---|---|
| exact-output sell (v2 in, WETH out) | 111.709 WETH | 98.5177% | 98.5178% | 328.9B v2: 67.7× the pool's v2, 12.8× the whole v2 supply (25.7B) |
| exact-output buy (WETH in, v2 out) | 4.861B v2 | 99.9606% | 99.9608% | 288,621 WETH: 67.6× all the WETH the PoolManager holds for every Base v4 pool (4,270.65) |

This matches the parent's analysis:

- The take fails exactly when the pre-fee input exceeds 1/0.015 = 66.7× what the manager holds of that currency.
- v2 exists only in this pool. For a sell, the limit is therefore 66.7× the pool's own v2.
- Against a full-range seed, that is a single swap draining 98.518% of the pool's WETH. The fraction does not depend
  on the pool's size.

**Verdict: NOT A DEFECT at launch.**

- Reaching it takes one exact-output swap that brings about 67× the pool's v2.
- All v2 in existence in the fork fixture is 5.3× the pool's v2. The parent's disposition (`SUMMARY.md`, a9d1e0544)
  reaches the same conclusion at full scale.
- Even at the threshold the outcome is a revert, never a loss, and the same trade fills as exact-input.

**When it could matter later.** Two situations:

- the full-range seed is withdrawn and in-range v2 becomes thin;
- the pool's v2 becomes a small fraction of a supply that one account holds and sells as exact-output.

The robust change is to collect the fee as ERC-6909 claims instead of calling `take()`. That is a hook redesign. The
parent recorded it as the future fix and deliberately did not make it before launch.

The threshold test passes today. It pins this premise: it goes red if a change to the seed or to the hook lets an
exact-output swap below a 98% drain fail the take.

### R2-2: stray tokens were stranded (REAL, low)

`withdrawTeam` and `withdrawBuyback` (`:136`, `:147`) are capped at owed − paid. So v2 or WETH sent to the hook by a
plain transfer (a pasted address, dust) could never leave, and "hook balance = unpaid fees" stopped holding.

- **Reproduced:** `test_ORACLE_hook_StrayTokensAreRecoverable` (`contracts/fee-hook/test/HookStrayTokenRecovery.t.sol`)
  fails on b62393184 with `stray token1 is stranded: nothing returns it`. It calls the parent's ABI,
  `recoverExcess(address currency, address to)`, spelled from the signature so the file compiles before the fix.
- **Fix (parent, 1ed281150):** a treasury-only `recoverExcess` that pays `balanceOf(hook) − Σ(owed − paid)`. This is
  the vault's `rescueV1` rule.
- **Verified on launch-readiness a9d1e0544:** the test passes, next to the parent's own same-named test in
  `test/HookOracleReview.t.sol`. fee-hook unit 28/28, fork 20/20.
- **Why a second test:** it covers three cases the parent's does not:
  - a currency the hook never charged;
  - fees partly withdrawn before the recovery;
  - the unpaid half staying withdrawable afterwards.
- **Mutants,** in a scratch copy of 1ed281150:
  - unpaid computed from `owed` alone, ignoring `paid`: this test fails, the parent's passes;
  - unpaid computed as `0`: both fail.

## The diff's own fixes

- **Oracle verdict:** H1, H2, H3 and H4 complete. Round 1 reported "no real defects".
- **Tests at b62393184:** their regressions (`test_H1_…`, `test_H2_…`, `test_H3_…`, `test_H4_…`) and the fork suite
  pass. Unit 26/26 without the new test; fork 20/20.

## Open questions the oracle raised

Buyback routing, cadence, slippage and burn. These are Safe policy (DESIGN.md open decisions), not hook defects.
