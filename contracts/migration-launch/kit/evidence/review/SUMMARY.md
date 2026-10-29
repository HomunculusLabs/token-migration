# §3.5 oracle review: disposition

RepoPrompt oracle reviews of each contract diff. Each ran two rounds, the second scoped to what the first
missed. Before any finding was triaged, every review passed a sanity probe: it quoted code from the reviewed
worktree verbatim. A finding counts as real only when a test reproduces it; the per-contract reports from
the review worker (`<contract>-oracle.md` in this folder) give each oracle question and the full triage.

## MigrationVault: 3 real, all fixed (189de9038)

- **The execution window was a race** (round 1, high). `activateClaims` had no time limit, so a late
  launch could pre-empt holders' timeout exit. Fixed: activation reverts after the deadline.
  `test_ORACLE_migration_ActivationAfterTheExecutionDeadline`.
- **Payouts were not capped at the committed total** (round 2, medium). A malformed root in an overfunded
  vault paid v2 nobody was promised. Fixed: both claim paths stop at `totalClaimable`, and the invariant
  suites assert it. `test_ORACLE_migration_PayoutsNeverExceedTheCommittedTotal`.
- **Deadline arithmetic could overflow** (round 2, medium). A huge window deployed, then panicked forever.
  Fixed: the constructor rejects it with `WindowTooLong`. `test_ORACLE_migration_ClaimPeriodThatOverflowsBricksActivation`
  and `test_ORACLE_migration_ExecutionWindowThatOverflowsIsRejected`.
- Each was red before its fix, and a mutant removing each fix is killed (`vault-fixes.txt`). The multisig
  e2e test activated one second after the window, so it had pinned the defect; it now activates at the
  deadline.

## SurplusFeeHook: 1 real and fixed, 1 known limitation

- **Tokens sent to the hook by mistake were stranded** (round 2, low). Fixed in 1ed281150:
  `recoverExcess`, treasury-only, pays only the balance above every unpaid fee.
  `test_ORACLE_hook_StrayTokensAreRecoverable`, red before the fix; a mutant ignoring the owed fees is killed
  (`hook-fix.txt`).
- **Exact-output swaps take the fee before the input arrives** (round 2, rated high by the oracle).
  `afterSwap` takes 1.5% of an exact-output swap's input from the PoolManager before the swapper pays
  anything in. The take fails only if the manager holds less of that currency than the fee.
  - WETH input never fails: the manager holds every Base v4 pool's WETH.
  - For v2 input, the manager holds the launch pool's own v2: the Safe's full-range seed, ~6.0B v2, which
    only grows as holders sell. A single exact-output sell would need a v2 input above ~400B v2, which is
    four times the whole v2 supply.
  - **Not reachable at launch.** It could arise only if the full-range seed were removed and in-range v2
    became thin. Even then it is a revert, never a loss: exact-input still fills.
  - The robust fix is to collect fees as ERC-6909 claims instead of `take()`. That is a hook redesign,
    recorded as the future fix, and deliberately not made before launch.

## SurplusTokenV2: no defects

The token rounds raised two test-coverage gaps, and both are covered elsewhere (`token-v2-oracle.md`).

## MigrationSettler: 1 real and fixed, 1 refuted

- **The settler could not tell the fee hook from any hook bound to it** (round 1, rated high by the oracle,
  medium here). It accepted the kit's fee-less stand-in and the real hook with a mistyped treasury.
  - Fixed: `_checkSuccessor` now also requires the hook's `TREASURY() == FEE_RECIPIENT` and `FEE_PIPS() == 15_000`.
  - Four regressions were red before the fix, and four mutants are killed (`settler-hook-pin.txt`).
  - The settler and hook addresses move; the vault, token and snapshot root do not. The full-scale rehearsal
    re-ran 7/7 green.
- **Permit2 expiration 0** (rated critical): refuted. Permit2 stores 0 as `block.timestamp`, and the fork trace
  shows both transfers succeeding.
- The settler's port hardening (S1–S4) is pinned by `test/fork/SettlerRegressions.fork.t.sol`.
