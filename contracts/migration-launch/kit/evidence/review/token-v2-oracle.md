# §3.5 oracle review: SurplusTokenV2

- **Diff:** `.review-diffs/token-v2.patch` on `contracts/token-v2`. It adds:
  - `BURNER_ROLE` and `burn`;
  - every role granted to the governance Safe, none to the deployer;
  - the storage-layout record and its gates (`scripts/check-storage-layout.sh`, `SurplusTokenV2StorageLayout.t.sol`);
  - DESIGN.md.
- **Result:** neither round found a contract or script defect. Round 1 raised two low test-coverage gaps. Both are
  **not defects**, for the reasons below, so no regression test was warranted.

## How it ran

- **Setup:** the same as the other reports (RepoPrompt oracle, review mode, workspace rooted at this worktree).
- **Context (27k tokens):** the diff, `SurplusTokenV2.sol`, `DESIGN.md`, `README.md`, the token suites,
  `GovernanceDouble` and the layout script.
- **Sanity probes:** round 1 quoted the three role constants, round 2 `burn`; both exact.

The two rounds asked:

- **Round 1:**
  - initializer and upgrade safety;
  - role wiring, and what the deployer or a third party can do;
  - cap semantics with burn;
  - the layout against OZ 4.9.6's gaps;
  - false negatives of the layout script;
  - the token's part in the launch batch, in the vault's balance checks and in the hook's `take()`.
- **Round 2** excluded round 1's findings and went deeper:
  - OZ 4.9.6 specifics: `_disableInitializers`, `onlyProxy`/`notDelegated`, the rollback check;
  - `getRoleAdmin` and escalation paths;
  - burn at the cap boundary;
  - whether the script's normalization can hide a real layout change;
  - front-running before the batch.

  The answer was "No new findings", with a reason for each area.

## Findings

| # | Oracle rating | Finding | Verdict |
|---|---|---|---|
| R1-1 | low | the launch-batch tests model two mints to a generic `launchHelper`, not the fixed five-call batch | **not a defect**: the batch itself is tested where it runs |
| R1-2 | low | the token/vault integration test uses `PRO_RATA_ENABLED = false` and a 180-day claim period, not the launch parameters | **not a defect**: reproduced with the launch parameters, and it passes |

### R1-1: the launch batch is tested in the launch project

`test/TokenFixture.sol:75-82`. The gap is real in the token suite, and deliberate. That suite's subject is the token's
part of the batch: two mints, atomic under the cap.

The full fixed batch runs in `contracts/migration-launch` on the pinned fork, through the real Safe 1.4.1 and
MultiSendCallOnly (`LaunchForkBase._batch`), with the real v2 proxy as the token:

1. `mint(vault, backing)`
2. `activateClaims`
3. `withdrawV1ForSettlement(settler, total)`
4. `mint(settler, lpBudget)`
5. `settle`

Its tests are `test_Launch_V2SortsAboveWeth` and `…BelowWeth`, the batch-revert tests and `RealHookLaunch`. All pass
at b62393184 (`oracle-review-runs.txt` §2). A wrong recipient or a wrong order in the batch would fail those tests;
it cannot slip past through the token suite.

### R1-2: the launch vault parameters change nothing on the token side

`test/SurplusTokenV2Migration.t.sol:26-35`. This was reproduced rather than argued. A probe drove the real
`SurplusTokenV2` proxy through a `MigrationVault` deployed with the launch parameters: pro-rata on, rate 10 000,
`claimPeriod` 0.

- `claimProRata` paid through the proxy.
- `claimWindowEnd` was `type(uint256).max`.
- A relayed root claim paid its leaf's account ten years later.
- The vault ended with no v2, supply equalled the backing, and the v1 settlement exit worked.

**The probe PASSES at b62393184.**

- The token plays the same part under either flag: the vault only calls `balanceOf` and `transfer` on it.
- The vault's own pro-rata and no-expiry behavior is covered in `contracts/migration`: the `test_ProRata*` tests and
  `MigrationVaultNoExpiryInvariantTest`.
- The probe stays out of the suite as review evidence, in the git-excluded `.review-diffs/probes/`. Its output is in
  `oracle-review-runs.txt` §8.

## The diff's own changes

Both rounds judged these complete:

- `BURNER_ROLE` adds no storage, and `burn` destroys only the caller's own balance.
- Roles go to governance only.
- The implementation is locked, and the proxy is initialized in its constructor.
- `_authorizeUpgrade` is gated by `UPGRADER_ROLE`.
- A burn frees cap headroom, as documented.
- The layout gates catch slot, offset and type moves.

The token suite passes at b62393184: 29/29.

## Open questions the oracle raised

All of them are already open §6 / DESIGN.md §8 decisions:

- the cap, the backing, the LP budget and the Safe;
- who holds the tokens when `burn` is called. The buyback executor must hold both the tokens and `BURNER_ROLE`.
