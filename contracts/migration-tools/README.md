# `contracts/migration-tools`

Off-chain Merkle tooling for the SURPLUS v1 → v2 migration (SUR-658 follow-up): turns a
deposits CSV into a deployable, independently verifiable claim tree for
`contracts/migration`'s `MigrationVault.commitRoot`, and proves the tree against the REAL
vault on-chain. No deployable contracts live here.

```bash
forge build --deny warnings            # warning-clean (CI gate, mirrors contracts/migration)
forge script script/BuildTree.s.sol    # input/deposits.csv → output/tree.{json,csv}; no RPC
forge script script/VerifyTree.s.sol   # re-verify tree.json locally; non-zero exit on any failure
forge test --match-contract TreeParity # on-chain parity vs the real MigrationVault
forge fmt --check
```

## The leaf format (frozen — do not invent a different one)

The vault verifies `keccak256(abi.encodePacked(index, account, amount))` — the Uniswap
reference distributor format, NOT OZ's StandardMerkleTree double-hash (see
`contracts/migration/DESIGN.md` §4). Nodes hash as OpenZeppelin 4.9.6's
`MerkleProof._hashPair`: sorted pair, single keccak. Odd-level tails are **promoted
unchanged** (the Uniswap/`TestMerkle` convention the vault's proofs already follow) — never
zero-padded, because the on-chain verifier folds exactly the siblings handed to it. Both
rules are mirrored in `src/ClaimTree.sol` and pinned by `test/TreeParity.t.sol`, which
compares against the migration suite's INDEPENDENT builder and drives the real vault's
`claim()` at boundary indices (0, last, 31/32/33, 63/64/65, plus n=1).

## Files

- `src/ClaimTree.sol` — the engine (leaf mirror + levels + proofs, non-mutating, O(n log n)).
- `script/BuildTree.s.sol` — `input/deposits.csv` (`account,amount`, raw wei, one header
  line, `#` comments) → `output/tree.json` `{root,total,leafCount,leaves[]}` +
  `output/tree.csv` (`index,account,amount`, the publication file). Row order = leaf index.
  Rejects malformed rows, zero amounts, duplicate accounts.
- `script/VerifyTree.s.sol` — re-hashes every leaf, recomputes the root, re-derives every
  proof, checks totals and indices. With `input/claims.csv` (`index,account,amount`) also
  folds each stored proof to the root. Pure keccak, no fork; reverts (exit 1) on any failure.
- `script/TreeIO.sol` — shared minimal `Vm` surface + CSV parsing (same no-forge-std stance
  as `contracts/migration/test/Base.t.sol`).
- `test/TreeParity.t.sol` — 11 tests: real-vault claim parity at edge indices, tamper
  rejections (wrong account/index/amount, sibling-substituted + truncated proofs), builder
  parity vs `TestMerkle` at several sizes, single-leaf tree.
- `input/deposits.sample.csv` — 5-row sample (real deposit lists are gitignored).

## Operational notes

- Run both scripts from this directory (paths are relative; `fs_permissions` bounds them to
  `./input` and `./output`).
- Before every `commitRoot`: publish `tree.csv`, have a second party rebuild from the same
  CSV, and diff roots — the dossier §04 review process this tooling exists to support.
- The vault binds indices globally; never reorder or edit a published CSV. A correction is a
  separately funded, non-overlapping process (DESIGN.md §4).
- Sized for real holder counts: output is streamed and the verifier decodes the tree once, so the
  full 6,347-holder Base cohort builds in ~6 s and verifies in under 1 s.

## Related issues

- SUR-658 — the vault this tooling feeds (leaf format frozen there).
- SUR-661 / SUR-662 — the v2 token and the multisig expected to run `commitRoot`.
