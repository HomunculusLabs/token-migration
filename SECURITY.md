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
  substitute for an independent audit. The successor-pool hook was cut down after those reviews:
  its initializer gate is unchanged and the fee code was removed
  ([`contracts/pool-hook/DESIGN.md`](contracts/pool-hook/DESIGN.md)).

## Known limitations and trust assumptions

- **The pool hook only controls who creates the pool.** `SurplusPoolHook` lets only the launch
  initialize the official V2/WETH pool. It holds only the `BEFORE_INITIALIZE` permission, so
  Uniswap never calls it on a swap or a liquidity change, and it takes no fee: the pool's 1.2% LP
  fee is the only fee the launch sets. Uniswap's governance can switch on a protocol fee for any v4
  pool, at most 0.1% of a swap. It cannot stop anyone from opening a separate V2/WETH pool elsewhere, at
  any fee. The exact-output limitation earlier versions of this file described belonged to the
  previous 1.5% fee hook, which was dropped before launch.
- **The claims tree is checked off-chain per leaf.** On chain, the vault requires the committed
  total to equal the net deposit ledger at the migration rate (pro-rata mode, which this migration
  uses) and caps every payout at that total. That each leaf pays the right account the right amount
  is verified by the kit's independent tree checks and by the Safe signers before they commit the
  root (finding M-01 in the internal review). Should a mis-allocated tree be committed anyway, an
  account the tree omits is still paid in full by `claimProRata()`, but a relayed under-paying leaf
  forecloses that account's proofless claim (issue #10); the audit's optional leaf-bound and
  partial-payment hardenings are the recorded backstops if a future contract change is cut.
- **The Safe governs.** The migration Safe holds every V2 token role (admin, minter, burner,
  upgrader) and receives every LP NFT the launch mints. Each privileged function and its limits are
  listed in the projects' `DESIGN.md` files.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: open the **Security** tab of this
repository and choose **Report a vulnerability**. Do not open a public issue for a security report.
