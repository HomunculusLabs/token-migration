# Security

## Status

- **Not deployed to Base mainnet.** The mainnet parameters in
  `contracts/migration-launch/kit/params.json` stay `TBD` until launch. Official contract
  addresses will be announced through the project's official channels and verified on Basescan.
  Do not trust addresses from anywhere else.
- **Not independently audited.** The contracts have had an internal review: unit, fuzz and
  invariant suites; Base-fork tests against the live Uniswap v4, Permit2 and Safe deployments;
  Slither and Aderyn; and AI-assisted review rounds whose findings were reproduced as failing tests
  before they were fixed. See `docs/internal-security-review-2026-10-04.md` and
  `contracts/migration-launch/kit/evidence/review/SUMMARY.md`. An internal review is not a
  substitute for an independent audit.

## Known limitations and trust assumptions

- **Fee hook, exact-output swaps.** The hook takes its fee on an exact-output swap before the
  swapper's input arrives, so such a swap reverts if the PoolManager holds less of the input
  currency than the fee. Reachability depends on the input-currency reserves, supply and actual
  launch configuration; it is not an invariant enforced by the hook. The earlier estimate of a
  sell roughly four times the whole V2 supply belongs to the historical two-sided full-range
  rehearsal, not the current split seed. Do not carry that numerical assurance forward without a
  new measurement bound to the intended source revision, block and final launch parameters, in
  both currency orientations. This reserve limitation reverts the affected swap atomically; it
  does not transfer funds on a reverted swap. Exact-input swaps do not have this pre-input
  collection condition, but still have their normal liquidity and slippage constraints. The
  historical mechanism analysis and proposed ERC-6909 redesign are in
  [`SUMMARY.md`](contracts/migration-launch/kit/evidence/review/SUMMARY.md); that redesign is not
  implemented in the current hook.
- **The claims tree is checked off-chain per leaf.** On chain, the vault requires the committed
  total to equal the net deposit ledger at the migration rate (pro-rata mode, which this migration
  uses) and caps every payout at that total. That each leaf pays the right account the right amount
  is verified by the kit's independent tree checks and by the Safe signers before they commit the
  root (finding M-01 in the internal review).
- **The Safe governs.** The migration Safe holds every V2 token role (admin, minter, burner,
  upgrader) and receives every LP NFT the launch mints. Each privileged function and its limits are
  listed in the projects' `DESIGN.md` files.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: open the **Security** tab of this
repository and choose **Report a vulnerability**. Do not open a public issue for a security report.
