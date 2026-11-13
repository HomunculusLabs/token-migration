# SURPLUS token migration

Contracts and launch tooling for the 1:1 migration of SURPLUS from V1 to V2 on Base: the vault holders
deposit into, the V2 token, the hook that guards the new V2/WETH pool, the Merkle tooling, and the launch
contract and kit that stage every Safe transaction for launch day.

> **Status:** not yet deployed to Base mainnet, and not independently audited. Read
> [SECURITY.md](SECURITY.md) first. Holders: the plain-language guide is
> [`contracts/migration-launch/kit/HOLDERS.md`](contracts/migration-launch/kit/HOLDERS.md).

## How it works

Holders deposit V1 into a vault during a fixed window. When the window closes, a claims list is built
from the deposits and the project's Safe multisig commits it to the vault. The Safe then launches in one
transaction: it funds every claim with V2, opens claims, sells the deposited V1 and opens a new V2/WETH
pool with the proceeds. Each holder then claims their V2, at 1 V2 per V1. If the launch never happens,
every depositor can take their V1 back.

### 1. Deposit window

- A holder approves the vault on V1, then calls `deposit(amount)` on `MigrationVault`. The vault records
  the deposit against the sender's address in its own ledger.
- Until `DEPOSIT_DEADLINE`, `withdrawV1(amount)` returns any part of it. `availableToWithdraw(account)`
  shows an account's net deposit (deposited minus withdrawn).
- A plain V1 transfer to the vault is not a deposit: it is not recorded and earns no V2.
- V1 in a liquidity position, in the Doppler fee contract or on another chain has to come back to a
  wallet on Base first (see "Who can't simply deposit" in
  [HOLDERS.md](contracts/migration-launch/kit/HOLDERS.md)).

### 2. Freeze and the claims list

- At `DEPOSIT_DEADLINE` the ledger freezes: no more deposits or withdrawals.
- The kit's snapshot reads every depositor from the vault's own `DepositIssued` events and each one's net
  deposit from the frozen ledger, and checks that they add up to the vault's on-chain total. The list has
  one entry per account with a net deposit above zero, at 1 V2 per V1, sorted by address, so anyone can
  rebuild the same list and Merkle root from the chain. It is published as `tree.csv` and `tree.json`.
- The Safe calls `commitRoot(root, total)`. The vault accepts it only after `DEPOSIT_DEADLINE` and no
  later than `COMMIT_DEADLINE`, and only if `total` equals the whole net ledger at 1 V2 per V1. The vault
  checks the total; each entry is checked off chain by the kit and the Safe signers (finding M-01 in
  [SECURITY.md](SECURITY.md)).

### 3. The launch, in one Safe transaction

The Safe DELEGATECALLs `MigrationLaunch.launch()` once. The launch contract runs only as the Safe, and
only if the committed total and the ledger match the ones it was built for. Then it:

1. mints the V2 for every claim into the vault;
2. calls `activateClaims()`, which requires the vault to hold that full backing and the execution window
   (28 days from the commit) to still be open;
3. releases the deposited V1 to the settler with `withdrawV1ForSettlement`, which the vault allows only
   once claims are active;
4. mints the V2 for the new pool to the settler;
5. calls `MigrationSettler.settle`, which:
   - sells the V1 on V1's two pools, the Doppler v4 pool and the Uniswap v3 1% pool, in the split that raises
     the most WETH. The kit works that split out from both pools as they stand when the launch is signed, so
     the v3 pool gets no V1 if it has nothing to add. It gets at most 70% of the V1 it could take then, so its
     part of the sale still fills if others use up to the other 30% before the launch executes;
   - opens the V2/WETH pool at the opening price fixed in the launch contract: V1's price before the
     sale, as measured in the launch simulation;
   - seeds it on both sides of that price. The V2 side copies the V1 that V1's old pool (the Doppler
     pool) still had for sale above V1's price, with the same amounts over the same price ranges. The
     WETH side holds the WETH the sale raised;
   - mints every LP NFT to the Safe and sends anything left over (unused V2, rounding dust) back to the
     Safe.

Afterwards it checks that every step happened and that nothing deciding who controls the Safe changed
(owners, threshold, modules, guard, fallback handler). If the sale raises less than `MIN_WETH_OUT`
(97% of what the launch simulation raised), or any check fails, the whole launch fails and nothing
moves.

### 4. Claim

After the launch, each depositor claims their V2 on the migration page or by calling the vault directly:

- `claimProRata()`, sent from the depositing wallet, pays that wallet's net deposit at 1 V2 per V1 straight
  from the vault's ledger. No proof is needed.
- `claim(index, account, amount, proof)` pays one entry of the committed list. Anyone can submit it, and
  the V2 always goes to `account`.

Each entry pays once, an account cannot be paid by both paths, and total payouts are capped at the
committed total. Claims never expire: this migration sets `CLAIM_PERIOD` to 0.

### If the launch does not happen

- Before the list is committed, the Safe can call `cancel()`.
- If no list is committed by `COMMIT_DEADLINE`, anyone can call `expireCommit()`.
- If claims are not opened within the execution window after the commit, anyone can call
  `expireExecution()`.

Each of these switches the vault to refunds. A depositor takes back their full net deposit with
`withdrawV1`, or anyone can call `refund(account)` for them, which always pays `account`. Until claims
open, every deposited V1 is still in the vault, so every refund is fully backed. Claims open inside the
launch transaction, and from then on the refund paths are closed for good.

### The new pool

The V2/WETH pool has one fee: 1.2% of every swap, the LP fee set in the pool key. It goes to the
pool's liquidity providers. At launch all of that liquidity is the Safe's, so the Safe earns the whole
fee and collects it like any LP. Anyone who adds liquidity later earns a share in proportion to their
in-range liquidity. There is no hook fee and no team or buyback split. As on any Uniswap v4 pool,
Uniswap's governance could switch on its own protocol fee, at most 0.1% of a swap; V1's pool pays none
today.

The pool's hook, `SurplusPoolHook`, makes sure only the launch can create the pool, so nobody can open
it first at a price of their choosing. Uniswap calls it once, when the pool is created, and never on a
swap or a liquidity change. It has no owner, admin, pause, setter, upgrade path or funds.

### Who holds which power

The Safe owns the vault. It commits the claims list, can cancel before the commit, and opens claims. It
can move deposited V1 only once claims are open, and claims open only when every claim is backed with
V2. Before that, it can rescue only V1 sent to the vault outside the ledger. The vault is not
upgradeable.

The Safe also holds every V2 role (admin, minter, burner, upgrader) and receives every LP NFT, so it
controls the new pool's liquidity. V2's supply is capped and `burn` only destroys the caller's own
tokens, but V2 is upgradeable, and an upgrade can change any of its rules, the cap included. Removing
the last upgrader does not permanently disable upgrades while an admin remains: the admin can grant
`UPGRADER_ROLE` again. See the [role and recovery rules](contracts/token-v2/DESIGN.md#3-role-matrix).
Each project's `DESIGN.md` lists every privileged function and its limits, and
[SECURITY.md](SECURITY.md) lists the trust assumptions and known limitations.

## Layout

| Path | What it is |
|---|---|
| `contracts/migration/` | `MigrationVault`: the depositor-facing V1 → V2 escrow (deposits, Merkle commit, claims, timeout refunds). |
| `contracts/token-v2/` | `SurplusTokenV2`: the successor token (upgradeable, Safe-governed). |
| `contracts/pool-hook/` | `SurplusPoolHook`, the Uniswap v4 hook on the successor V2/WETH pool: only the launch can create the pool. It takes no fee. |
| `contracts/migration-tools/` | Merkle tree build and proof tooling (deposits CSV → root, claim proofs). |
| `contracts/migration-launch/` | `MigrationLaunch`, the one-call launch contract the Safe DELEGATECALLs once: it backs and opens claims, sells the migrated V1, opens and seeds the successor pool, and delivers the LP NFTs to the Safe. Also the `kit/` Python tooling (plan → simulate → snapshot → Safe packets → launch batch), the fuzz and invariant suites, and the runbook. |
| `anvil-lab/` | A self-contained Base-fork diagnostic harness: v4 pool discovery, hook/LP probes, sale route comparisons, offline math tests (`anvil-lab/run.sh probe\|compare`). |
| `docs/internal-security-review-2026-10-04.md` | The internal security review (not an independent audit). |
| `docs/launch-tbd-decision-set-2026-10-05.md` | Recommendations for every `TBD` in the kit's `params.json`. |

Each contract project has a `DESIGN.md`: what the contract enforces, what it deliberately does not,
and who holds which power. The launch procedure is `contracts/migration-launch/kit/RUNBOOK.md`.

The `contracts/` nesting is load-bearing. Every project resolves `@openzeppelin/...` through
`../../node_modules/` and its sibling projects as `../<project>/`, so dependencies install once at
the repository root.

## Requirements

- [Foundry](https://getfoundry.sh), tested with forge 1.7.1. Each project pins solc 0.8.28 in its
  `foundry.toml`.
- Node.js and npm, for OpenZeppelin 4.9.6.
- Python 3.10 or newer for the kit (standard library only; it calls Foundry's `forge` and `cast`).

## Build and test

```bash
npm ci

(cd contracts/migration && forge build --deny warnings && forge test)
(cd contracts/migration-tools && forge build --deny warnings && forge test)
(cd contracts/token-v2 && forge build --deny warnings && forge test && python3 -m unittest discover -s __tests__ -p 'test_*.py')
(cd contracts/pool-hook && forge build --deny warnings && forge test)

# migration-launch: its fork suites need a Base fork (below), so exclude them here
(cd contracts/migration-launch && forge build --deny warnings && forge test --no-match-path 'test/fork/**')
(cd contracts/migration-launch && python3 -m unittest discover -s __tests__/kit -p 'test_*.py')
```

Green at this release: `migration` 118 tests, `migration-tools` 11, `token-v2` 42 (+2 Python),
`pool-hook` 14 (its fork suites skip without a fork), `migration-launch` 29 (unit, fuzz and
invariant), and the kit's 121. On the pinned fork below: `pool-hook` 22 and `migration-launch` 40
(one rehearsal-only suite skips without a rehearsal deployment).

### Fork suites

`pool-hook` and `migration-launch` also have suites under `test/fork/` that run against Base
mainnet at block 51,935,583, using the live PoolManager, Permit2 and Safe deployments. Start a
pinned fork from an archive RPC, then point the suites at it:

```bash
anvil --fork-url "$BASE_ARCHIVE_RPC" --fork-block-number 51935583 --port 18549
(cd contracts/pool-hook && forge test --match-path 'test/fork/**' --fork-url http://127.0.0.1:18549)
(cd contracts/migration-launch && forge test --match-path 'test/fork/**' --fork-url http://127.0.0.1:18549)
```

### On Base Sepolia

The migration has also run end to end on the public Base Sepolia testnet with throwaway keys:
refunds after a missed deadline, real wallets on the migration page and in the Safe app, the
one-call launch contract, and a load rehearsal with 5,000 wallets and 800,000 test V1. Addresses,
transactions and results for each run are in
[`contracts/migration-launch/kit/evidence/sepolia/`](contracts/migration-launch/kit/evidence/sepolia/).
Those runs exercise mechanics on a public chain, not Base-mainnet sale economics.

[`kit/REPORT.md`](contracts/migration-launch/kit/REPORT.md) preserves a **historical** mainnet-fork
rehearsal: a MultiSendCallOnly batch, one two-sided full-range position, and a V2 budget of simulated
usage + 0.1% + 10 wei. The current launch instead uses `MigrationLaunch`, separate V2-only ladder
ranges and a WETH-only position, and a V2 budget of simulated usage + 10 wei. The old report's LP
quantities, depth, supply and gas are not measurements of the current launch, and its fee figures
are for a 0.30% LP fee plus a 1.5% hook fee that the launch no longer has.

Current full-cohort economics and gas require a separately published, source- and block-pinned run
through the Safe's DELEGATECALL to `MigrationLaunch.launch()`, reconciling the claims, sale, LP
positions and signed limits. The included full-scale harness still uses MultiSendCallOnly, even
though its parameter builder now uses split ranges; it alone does not establish full-cohort
acceptance of the one-call launcher. Do not treat the historical report as the release gate.

## Security

See [SECURITY.md](SECURITY.md): deployment and review status, known limitations and trust
assumptions, and how to report a vulnerability privately.

## License

MIT; see [LICENSE](LICENSE). Third-party attributions are in [NOTICE](NOTICE).

## About this repository

The contracts were developed in Surplus Intelligence's monorepo and are published here as a
snapshot of the token-migration surface only. The September 2026 planning documents that
`contracts/migration/DESIGN.md` cites (the migration blueprint and the contract-candidates menu)
are not included.
