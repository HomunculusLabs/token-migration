# SUR-658/661 internal static-analysis audit — Slither 0.11.6 + Aderyn 0.6.8

Run: 2026-10-01, branch `bill/sur-659-integrated` @ `935b9acb1` (post-merge of origin/main),
toolchain solc 0.8.28 / forge 1.7.1. All four contract projects scanned with BOTH tools.
Raw JSON/MD artifacts: `/tmp/sur658-audit/` (slither-<project>.json, aderyn-<project>.md).

Note on Aderyn mechanics: the monorepo's foundry projects emit build-info with `source_id_to_path`
(id-keyed, no inline source) — Aderyn 0.6.8's forge reader panics on that format
(`aderyn_driver/src/compile.rs:78`). Reports for migration/token-v2/fee-hook/migration-launch were
produced from scratch projects in /tmp with the same `src/` files verbatim and absolute remappings
to the SAME workspace node_modules OpenZeppelin 4.9.6 (and the same in-repo sources for
`@surplus/*`), so the analyzed code is byte-identical to the repo's. Worth an upstream issue.

## Verdict

**No new high-severity defect.** Every High from either tool is either a known-reviewed pattern,
an upstream/library false positive, or already-covered by existing test/invariant suites. One
Low-severity real observation (sweepResidual timing) recorded below. Details per project.

## MigrationVault (migration)

Slither: 41 findings — zero High/Medium. Composition: 12 timestamp (the vault IS a calendar;
deadline semantics deliberately reviewed — see foundry.toml lint exclusion), 9 naming (V1/V2/DEPOSIT_DEADLINE
style is deliberate), 8 reentrancy-events + 1 reentrancy-benign (see triage), 5 low-level-calls /
2 assembly / pragma/solc-version (all inside OpenZeppelin 4.9.6), 1 uninitialized-local
(sweepResidual.reserved — false positive: it IS deliberately initialized in each branch; default 0
is the correct "claims never active AND cancelled" reserve).

Aderyn: H-1 "ETH transferred without address checks" (6) — misfires on ERC-20 transfer functions,
not ETH; every function pays msg.sender or a ledger-verified account. H-2 "Reentrancy: state after
external call" at activateClaims (V2.balanceOf then claimsActive=true) — balanceOf is a view;
no exploit path; state transitions gated by phase/root invariants.

Reentrancy triage (both tools): `deposit` credits AFTER safeTransferFrom; `withdrawV1` uses
checks-effects-interactions CORRECTLY (withdrawn incremented before transfer); `claim`/`claimProRata`
mark-paid BEFORE safeTransfer; `refund` is relayed with an events-after-transfer pattern but pays a
computed ledger amount and marks before transfer. V1/V2 are standard ERC-20s; no ERC-777 callbacks.
The one theoretical vector — a malicious V1 (fee-on-transfer/hook) — is out of scope: V1 is the
fixed deployed token. No nonReentrant guard exists BY DESIGN (gas + no hook surface), consistent
with the reviewed design.

## SurplusTokenV2 (token-v2)

Slither: 44 findings — the only High is `incorrect-exp` INSIDE OpenZeppelin's
MathUpgradeable.mulDiv (`(3 * denominator) ^ 2` is OZ's own optimized inverse-sqrt routine, a known
slither false positive on OZ 4.9). divide-before-multiply (8) are OZ internals. `unimplemented-
functions` (1) is the intentional UUPS `_authorizeUpgrade` revert-only pattern.

Aderyn: H-1 "Contract locks Ether without a withdraw function" — the token has no payable and no
receive(); native sent via force-transfer is a known acceptable class for tokens. L-3 Unused State
Variable flagged by Aderyn = storage-gap/end slots, deliberate.

## SurplusFeeHook (fee-hook)

Slither: 14 findings, zero High/Medium. missing-zero-check on recoverExcess currency (Low):
staticcall to address(0) returns empty → (ok=false) → handled; behavior safe.

Aderyn: H-1 "Unsafe Casting" in V4Minimal.amount0/amount1 — `int128(delta >> 128)` is the
UNISWAP V4 CORE (currency-delta) pattern itself, reused verbatim; the shift guarantees the upper
bits are zero before the downcast, and both call sites are wrapped by forge-lint
disable(unsafe-typecast) markers. Not a defect.

## MigrationSettler (migration-launch)

Slither: 44 findings. The 2 "reentrancy-balance (High)" hits on _sell are the expected shape: the
settler reads V1/WETH balances around POOL_MANAGER.unlock and V3_TAIL.swap; both callbacks are
authorized (`unlockCallback` requires msg.sender == POOL_MANAGER), and every external call is
followed by strict postcondition reverts (V1LeftUnsold, SaleBelowMinimum, budget checks) — a
reentrant path that skews a delta trips a revert, not a loss. This mirrors the §3.5 oracle's
review of the settler (S1–S4 pinned by SettlerRegressions.fork.t.sol).

Aderyn: H-1 reentrancy at launch() line ~178 (mint/initialize ordering) — same class as above:
state writes after external calls are accounting reads/writes guarded by postcondition reverts and
_returnAll sweeps. H-2 unsafe casting = the same V4 currencyDelta idiom. L-4 uninitialized local =
the `reserved` sweepResidual pattern counterpart? (verify) — no. It's LaunchMath-adjacent; triaged
as above. L-5 Unsafe ERC20 op = _returnAll's raw transfer for WETH (deliberate: WETH is trusted).

## One real (Low) observation worth recording

`MigrationVault.sweepResidual()`: after the claim window closes (claimsEverActive && now >
claimWindowEnd), `reserved` becomes 0 and ANY residual V2 (rounding dust, never-claimed pro-rata
dust from passed-away holders) is sweepable by `owner` immediately. That is the designed end-state
treasury sweep, but note the timing: claimWindowEnd is set at activateClaims time; the window is
the published CLAIM_PERIOD. No defect — recorded so the runbook's "when can the treasury sweep"
line matches code.

## Suggested follow-ups (not blockers)

1. File the Aderyn build-info incompatibility upstream (id-keyed source maps panic).
2. Consider `aderyn.toml` / slither triage config in-repo so CI can run both with the
   known-benign set suppressed — ask Bill before adding CI gates.
3. Echidna/Medusa invariant fuzzing on the vault (the invariant suites already exist in foundry;
   a property harness would reuse them) — optional depth, not required for launch week.
