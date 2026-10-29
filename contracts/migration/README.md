# `contracts/migration`

Custody, deposit ledger and Merkle claims for the SURPLUS v1 → v2 token migration (SUR-658).
One contract — `MigrationVault` — plus its test suite. **Read [`DESIGN.md`](./DESIGN.md) before
touching anything**: it records the phase machine, the ordering rule that makes the escrow honest,
the leaf format, and the list of things deliberately left out.

```bash
forge build --deny warnings   # must be warning-clean (CI gate, mirrors contracts/payments)
forge test                    # 58 behavior tests
forge fmt --check
```

OpenZeppelin resolves from the workspace root's npm-pinned 4.9.6 via `remappings.txt` — no git
submodule, no vendored copy (same stance as `contracts/payments`; see `test/Base.t.sol`'s header).

## The one-paragraph version

Holders deposit v1 in an open window; the vault never trades it while open. At close, the operator
commits an allocation root (point of no return) and must then post FULL v2 backing before a single
v1 leaves the vault for settlement. Claims pay the leaf's beneficiary — relayers can't redirect.
If the ratified allocation is a flat ratio, holders may instead call `claimProRata()` and be paid
from the vault's own ledger — no proof, no index, no website. Anyone can call `verifySettlement()`
to check backing coverage at any moment. If the operator vanishes after commitment, anyone can
trigger the timeout and holders pull their v1 back against the same root, no signer required.
Unclaimed entitlements are liabilities, never sweepable. Deposits and withdrawals emit
reconciliation receipts (net running balance) the indexer must reproduce exactly.

## Layout

- `src/MigrationVault.sol` — the vault.
- `test/MigrationVault.t.sol` — behavior suite (58 tests), organized by phase.
- `test/TestMerkle.sol` — independent Merkle builder matching the vault's EXACT leaf format, so
  generator/verifier drift is a test failure.
- `test/MockERC20.sol` / `test/Base.t.sol` — test doubles (see headers).

## Related issues

- SUR-658 — this contract (build + test).
- SUR-661 — the v2 token it pays out.
- SUR-662 — the multisig expected to own it.
- SUR-663 — bridging (explicitly out of scope here).
