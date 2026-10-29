# Deep-fuzz campaign (SUR-658 audit week)

Run: 2026-10-01, branch `bill/sur-659-integrated` @ `558f55bf9`, foundry 1.7.1 / solc 0.8.28,
profile `deep` (fuzz 20,000 runs; invariant 2,000 runs × 256 depth). Raw log: this file's sibling,
`deep-fuzz.log` (verbatim command output). Command:

    NX_DAEMON=false npx nx run-many -t fuzz \
      -p '@surplus/contracts.migration' '@surplus/contracts.token-v2' \
         '@surplus/contracts.fee-hook' '@surplus/contracts.migration-launch' --skip-nx-cache

## Results — zero failures, all four projects

- **@surplus/contracts.migration** — 10 suites, 118 tests, 0 failed (192.73s wall, 1127s CPU).
  All seven standing invariants at 2,000 runs × 512,000 calls, reverts: 0 each, run TWICE
  (both constructor variants — never-expiring and expiring claims):
  ConservationV1, ConservationV2, LedgerNeverOverdrawn, NoIndexEverPaidTwice,
  OpenEntitlementsStayBacked, OrderingHolds, RootIsImmutableAfterCommit.
  Adversarial property suite at 20,000 runs per test (phase-transition matrix, bitmap
  boundaries 31/32/33 + 63/64/65, Merkle sibling substitution / proof reuse / leaf reuse).
- **@surplus/contracts.token-v2** — 3 suites, 29 tests, 0 failed.
- **@surplus/contracts.fee-hook** — 5 suites, 28 tests, 0 failed (includes
  testFuzz_ChargesExactlyTheFeeOnTheUnspecifiedCurrency at depth).
- **@surplus/contracts.migration-launch** — offline suites green (fork suites excluded from the
  fuzz target exactly as the test target excludes them; they run under `nx fork` against a live
  Base fork).

Depth delta vs the committed default profile: fuzz 512 → 20,000 (×39), invariant 128×64 →
2,000×256 (×62.5 runs, ×4 depth). No new findings at any depth.

## Gate wiring (same commit)

- CI (main only): `scripts/contracts-static-analysis.sh` — Slither over all four projects with
  the reviewed detector-level allowlist; any finding outside it fails the job. Negative-tested
  by injecting a tx.origin-authorization defect: gate reported FINDINGS / exit 255; clean tree
  exits 0. Aderyn stays local (`scripts/contracts-aderyn-gate.py`) until upstream fixes the
  id-keyed build-info reader panic.
- `nx fuzz` target per contracts project (`FOUNDRY_PROFILE=deep`), fork suites excluded.
