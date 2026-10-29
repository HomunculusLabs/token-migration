# SURPLUS token migration

The on-chain surface for the **SUR → SURPLUS (V1 → V2) token migration** on Base: the deposit
vault, the V2 token, the successor pool's fee hook, the Merkle tooling, and the launch kit that
plans, simulates and stages every Safe transaction for launch day.

> **Status:** not yet deployed to Base mainnet, and not independently audited. Read
> [SECURITY.md](SECURITY.md) first. Holders: the plain-language guide is
> [`contracts/migration-launch/kit/HOLDERS.md`](contracts/migration-launch/kit/HOLDERS.md).

## Layout

| Path | What it is |
|---|---|
| `contracts/migration/` | `MigrationVault`: the depositor-facing V1 → V2 escrow (deposits, Merkle commit, claims, timeout refunds). |
| `contracts/token-v2/` | `SurplusTokenV2`: the successor token (upgradeable, Safe-governed). |
| `contracts/fee-hook/` | The Uniswap v4 hook that takes the 1.5% fee on the successor V2/WETH pool. |
| `contracts/migration-tools/` | Merkle tree build and proof tooling (deposits CSV → root, claim proofs). |
| `contracts/migration-launch/` | `MigrationLaunch`, the one-call launch contract the Safe DELEGATECALLs once: it seeds the successor pool, sells the migrated V1 through the signed curve, activates claims and delivers the LP NFTs. Also the `kit/` Python tooling (plan → simulate → snapshot → Safe packets → launch batch), the fuzz and invariant suites, and the runbook. |
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
(cd contracts/fee-hook && forge build --deny warnings && forge test)

# migration-launch: its fork suites need a Base fork (below), so exclude them here
(cd contracts/migration-launch && forge build --deny warnings && forge test --no-match-path 'test/fork/**')
(cd contracts/migration-launch && python3 -m unittest discover -s __tests__/kit -p 'test_*.py')
```

Green at this release: `migration` 118 tests, `migration-tools` 11, `token-v2` 42 (+2 Python),
`fee-hook` 28 (its 4 fork tests skip without a fork), `migration-launch` 27 (unit, fuzz and
invariant), and the kit's 91. On the pinned fork below: `fee-hook` 20 and `migration-launch` 40
(one rehearsal-only suite skips without a rehearsal deployment).

### Fork suites

`fee-hook` and `migration-launch` also have suites under `test/fork/` that run against Base
mainnet at block 51,935,583, using the live PoolManager, Permit2 and Safe deployments. Start a
pinned fork from an archive RPC, then point the suites at it:

```bash
anvil --fork-url "$BASE_ARCHIVE_RPC" --fork-block-number 51935583 --port 18549
(cd contracts/fee-hook && forge test --match-path 'test/fork/**' --fork-url http://127.0.0.1:18549)
(cd contracts/migration-launch && forge test --match-path 'test/fork/**' --fork-url http://127.0.0.1:18549)
```

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
