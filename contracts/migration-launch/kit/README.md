# Launch kit

Everything the SURPLUS v1 → v2 launch needs, in one folder. Launch day comes down to: fill in the open
decisions in `params.json`, run one command per phase, review, sign. The kit never broadcasts to Base;
Safe simulations and explicit rehearsal helpers transact only on isolated loopback Anvil instances.

```
python3.14 kit/launch.py <phase> …      # from contracts/migration-launch/
```

- `deploy-plan`: every address (the Safe, the v2 implementation and proxy, the vault, the settler, and the
  hook at a mined 0x2044 salt), init-code hashes, Basescan inputs, and a dry run of all six deployments on
  a fork.
- `snapshot-plan`: sizes the snapshot's log pages for the real deposit window and proves the RPC serves them
  (`--probe` tests a candidate RPC before launch; `--vault … --run` plans and runs the launch-day snapshot).
- `snapshot`: the vault's deposits at a block → `deposits.csv` → tree → three independent verifications
  → `commitRoot` inputs.
- `safe-txs`: the `commitRoot` Safe transaction, and the launch: one contract (`src/MigrationLaunch.sol`)
  holding every launch number, run by one Safe DELEGATECALL. Each comes as raw calldata and a safeTxHash (plus
  Transaction Builder JSON for `commitRoot`, and the contract's deployment for the launch), with limits set by
  simulate-then-sign.
- `push-plan`: Multicall3 claim batches (< 128 KB, < 2^24 gas each), safe to rerun, with a cost estimate.
- `check`: every artifact matches `manifest.json`, regeneration is byte-identical, and the only `TBD`s
  left are the spec §6 decisions.

## Files

- `params.json`: every launch input. Open decisions are the literal `"TBD"`, and each section names the
  decision that owns it. A phase that needs one stops and names it.
- `params.rehearsal.json`: the same file with the rehearsal defaults and public throwaway keys. Phases
  accept it only with `--rehearsal`.
- `RUNBOOK.md`: the launch-day sequence, who signs what, and every abort path.
- `SIGNER-CHECKLIST.md`: what each Safe signer checks before signing.
- `HOLDERS.md`: for holders. Addresses, how to deposit, how to check your own entry.
- `REPORT.md`: the full-scale rehearsal's numbers at the pin.
- `manifest.json`: sha256 of every artifact (`check` verifies it).
- `evidence/`: command output behind every claim in REPORT.md and the spec's progress list.
- `output/` (gitignored): large generated files. The manifest records their sha256.

## Verification

From the repository root:

```bash
npx nx run @surplus/contracts.migration-launch:kit-test
npx nx run-many -t lint test build -p '@surplus/contracts.*' --skip-nx-cache
```

The ordinary migration-launch test target includes the offline Python regression tests. Python 3.14
is installed explicitly in CI; no Python packages are needed.

If a deposit rehearsal is interrupted, inspect the printed transaction hash before restarting: a receipt
wait timing out does not prove a revert. Rerun the same `rehearse.py deposit` command only after pending
transactions are resolved. It reconciles the cohort against the vault ledger, skips confirmed full
deposits, and refuses partial or unexpected state instead of depositing blindly. Reported transaction
gas covers only the transactions newly sent by that invocation.

The full-scale target requires the recorded pre-commit fork and matching deployment, cohort, expected
root, tree and snapshot files under `kit/output/`. It refuses missing inputs, the wrong block/hash,
skipped tests and partial runs. The large gas limit is for the aggregate harness only. Set
`RESTORED_PRECOMMIT_RPC` to the loopback URL of a restored pre-commit fork, not the instance that has
already executed the launch and payouts.

```bash
SURPLUS_REHEARSAL_RPC="${RESTORED_PRECOMMIT_RPC:?set the restored pre-commit fork URL}" \
SURPLUS_TREE=kit/output/snapshot/51948266/tree.json \
npx nx run @surplus/contracts.migration-launch:rehearsal
```

Those paths identify the recorded rehearsal, not production. A clean checkout needs the reviewed
output/data bundle or a rebuilt deposit rehearsal first; an empty `output/` is not a passing release
gate. Keep initial batch artifacts separate from terminal reconciliation, and retain their manifest.

A manifest freezes a reviewed packet, including its progress and execution evidence; it is not a live
progress dashboard. Further execution or replanning deliberately invalidates that packet's hashes.
Archive the prior packet and manifest, review the new results, then run `check --write` and `check`
for the new packet. Never rewrite a manifest merely to suppress an unexplained mismatch.

## Trust model

- Each phase is a pure function of `params.json`, the compiled contracts and chain state at a stated block.
  Two people running it get byte-identical output.
- The tree is verified three ways that share no code: the migration-tools `VerifyTree`, `VerifyTreeBulk`,
  and a pure-Python Keccak rebuild that also re-reads every leaf from the vault's own ledger.
- Every address is derived twice: by forge, and by an independent Python CREATE2 computation.
- Nothing here holds keys. Rehearsal-only helpers (`rehearse.py`, `script/RehearsalDeposits.s.sol`)
  refuse anything but a loopback anvil.
