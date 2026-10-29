# Token-Migration Suite — Internal Security Review (2026-10-04)

> **About this document.** This is the development team's own review, run with automated analysis
> (Slither, Aderyn, deep fuzzing, Base-fork tests) and AI-assisted review rounds. It is not an
> independent third-party audit. The gate results describe the revision named below; later
> revisions are covered by each project's own suites (see the README).

**Target:** `bill/sur-659-integrated` @ `c1092a39f` — `MigrationVault`, `SurplusTokenV2`,
`SurplusFeeHook`(+`V4Minimal`), `MigrationSettler`(+`LaunchMath`), `ClaimTree`, plus the
launch-kit surface. No contract-source change between the prior reviewed SHA `935b9acb1` and this
head (verified: `git diff` on `contracts/*/src` is empty), so prior evidence remains valid;
every gate below was re-run fresh on the head.

## Verdict

**Ship-shape.** No new code defect found by any layer. All mechanical gates green at head;
manual whole-contract review clean; oracle round-3 (whole-contract, prior findings excluded)
raised one High that re-fails verification (a known false positive refuted on-chain), one
documented-division-of-labor Medium, one tooling-hardening Low.

## Gate matrix (all run 2026-10-04 on c1092a39f)

| Gate | Result |
|---|---|
| `forge build --deny warnings` ×5 projects | ✅ warning-clean |
| Unit tests (canonical nx targets) | ✅ 190 pass / 0 fail (migration 118, token 29, hook 28+4 skip, launch 4+21 fork, tools 11) |
| Slither 0.11.6 gate (4 projects) | ✅ clean vs reviewed allowlist |
| Aderyn 0.6.8 gate (4 projects) | ✅ only reviewed-benign Highs |
| Deep fuzz `[profile.deep]` (4 projects) | ✅ 20,000 runs, 118 tests, 0 fail |
| Fork suites @ pinned Base 51935583 | ✅ green (real PoolManager/Permit2/Safe/v3) |
| nx lint/test/build (5 projects) | ✅ |
| Launch kit `check` | outputs live in this worktree (01–08); not re-run here — kit phases regenerate |
| Slither gate negative test | ✅ performed in this review: tx.origin injection → exit 1; restore → exit 0 |

## Manual review (whole-contract, this review)

No new defect. Notable verified properties:

- **Pro-rata rounding can't break the cap:** Σ floor(per-account) ≤ floor(aggregate) — the
  `commitRoot` aggregate equality plus per-account floors makes premature `ExceedsTotalClaimable`
  impossible from honest rounding.
- **Hook fee surface is closed:** any pool naming the hook must pass `beforeInitialize`'s
  official-key gate; `afterSwap` can only fire for the official pool, so cross-pool fee
  confusion is structurally prevented.
- **Settler donation-resistance:** sells exactly `v1In` (donations can't grow the sale), sizes
  the seed from `raised` (donations can't grow the seed), returns every residual to the Safe.
- **Refund backing by construction:** v1 exits only via settlement-withdrawal (claims-active
  gated) or rescue (excess-only); Cancelled-phase refunds always fully backed.
- **CEI on every paying function** (bitmap/flags before transfer; reentrancy findings triaged
  benign because V1/V2 are plain ERC-20s).
- **Token storage-layout gate:** two-way snapshot check (`scripts/check-storage-layout.sh`) green.

## Oracle round 3 (RepoPrompt, whole-contract, prior findings excluded)

Sanity probe verbatim-correct. Findings and dispositions:

| # | Finding | Disposition |
|---|---|---|
| H-01 | Permit2 expiration `0` = "already expired", mint reverts, funds frozen | **Refuted** (re-verified in this review): Permit2 reads expiration `0` as `block.timestamp` (valid through current block). Round 2 refuted with a fork trace; today's fork suites exercise the REAL deployed Permit2 through the actual mint and are green at the pin. |
| M-01 | Pro-rata mode validates only the aggregate total; malformed root could over-allocate one account | **Documented design** (division of labor): commitRoot binds the SUM; per-leaf correctness is a tree-build obligation authenticated at signing (kit + DESIGN.md). Residual procedural risk: a corrupted/malicious tree build remains an operational trust assumption. |
| L-01 | ClaimTree doesn't assert embedded index == array position | **Already covered at the pipeline layer**: `kit/snapshot.py` `verify_tree_py` (independent pure-Python verifier) fails the build on index≠position, sort order, amount≤0, malformed address, per-leaf ≠ on-chain ledger×rate, Σnet ≠ vault net ledger, root mismatch, or any proof that does not fold. The `ClaimTree` library deliberately stays general; the invariant belongs to the kit, which enforces it. |
| I-01 | Vault assumes exact-transfer ERC-20 (no fee-on-transfer) | Informational: V1/V2 are standard ERC-20s; assumption is sound for this launch. |

Round 1+2 dispositions unchanged: vault 3 fixed (red→green + mutation-killed), hook 1 fixed +
1 documented limitation (exact-output take, unreachable at launch, ERC-6909 redesign deferred),
settler 1 fixed + 1 refuted (this same Permit2 claim), token clean.

## Open items (operator decisions, not code defects)

`kit/params.json` carries 13 TBDs — governance.owners/threshold, token.name/symbol/capWei,
vault.depositOpen/depositDeadline/commitDeadline/executionWindowSeconds, hook.feeRecipient,
operators.deployer/relayer. Launch cannot proceed until decided (by design — the kit fails
loudly on a TBD).

## Tooling note

Slither gate is now **negative-tested** (tx.origin tripwire): injected → exactly 1 `tx-origin`
finding, gate exit 1; restored → exit 0.

## Addendum — empirical MEV red-team (2026-10-04, same session)

`test/fork/MevRedTeam.fork.t.sol` (committed): three searcher-shaped attack bundles on the
pinned Base fork, sequenced around the REAL Safe batch with the REAL 0.5% signed floor.
Attacker capital: 1M v1 (non-cohort whale) + 200 WETH for M1/M2; 460M v1 (half the whale's
real balance, ~10% of the launch's own 4.86B v1 sale) for M3.

| Scenario | Outcome | Searcher PnL (measured) |
|---|---|---|
| M1 classic sandwich (front-sell 1M v1 → launch → backrun buy-back) | Batch EXECUTED; launch lost 0.019% of proceeds, floor never approached | **+0.0227 WETH (~$77)** — real but dust; 25× under the 0.558 WETH floor margin. Bounded by pool depth, not by the floor. |
| M2 price-push (buy 100k v1 exact-out → launch → unwind) | Batch EXECUTED at *better* than simulated proceeds | +0.000147 WETH — noise |
| M3 whale grief (dump 460M v1 → batch → unwind) | Batch **ABORTED below floor**; abort verified clean (no activation, no mint, no v1 moved, nonce untouched, still inside the window) | Round-trip is path-neutral; the TRUE grief price = fees + gas = **0.247 WETH (~$800)**. The mark-to-market "loss" (0.82 WETH) is recoverable by unwinding. |

Conclusions: (1) sandwich profit at realistic searcher scale is real but bounded to dust by
pool depth — the 4.86B v1 launch dwarfs any plausible front-run; (2) tripping the floor
requires ~a tenth of the launch's own sale size in hostile v1, costs ~$800 in fees/gas,
buys only a re-signing round (fail-closed abort verified), and is unwound at neutral —
griefing exists but is expensive and pointless; (3) nothing anywhere loses holder funds.
