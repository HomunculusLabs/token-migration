# Launch decision set — the 13 TBDs in kit/params.json (2026-10-05)

Every item is **[owner: Bill]** except where noted. Recommendations are grounded in the vault
constructor's constraints, the internal review's timing facts, and the design docs; each needs an explicit
decision before `deploy_plan.py` will run (the kit fails loudly on any TBD it needs).

## A. Vault windows — `vault.*` (4 TBDs)

The vault pins these immutably at deploy; they are the holder-facing offer.

| # | Param | Recommendation | Why |
|---|---|---|---|
| A1 | `depositOpen` | **The deploy/announce day** (dates recorded, not a timestamp — the kit converts) | Deposits are open from deployment; the parameter records the announced opening. |
| A2 | `depositDeadline` | **A1 + 30 days** | Design doc's own offer-window guidance is 14–30d; 30d maximizes captured supply for a one-shot 1:1 flat migration. Anyone who misses it keeps tradeable v1 — no loss, no participation. |
| A3 | `commitDeadline` | **A2 + 7 days** | DESIGN.md: rehearsal used deadline+3d; this is "time to build + verify the tree + collect signatures." The internal review showed the kit's verification chain (Σ-reconciliation, per-leaf ledger checks) needs real wall-clock time; 7d is comfortable without extending holder limbo. |
| A4 | `executionWindowSeconds` | **7 days (604_800)** | DESIGN draft value. Bounds how long the Safe can sit between root commit and launch. Must outlive realistic Safe signing latency (threshold+1 rounds if MEV-griefed — measured grief cost to an attacker is ~$800 and buys only a re-sign). 7d ≥ several failed signing rounds. |

## B. Governance — `governance.*` (2 TBDs) — tracked by SUR-662

| # | Param | Recommendation | Why |
|---|---|---|---|
| B1 | `owners` | **3 signers: Bill + 2 (Mac/nominated) — confirm addresses out-of-band** | The launch Safe holds every v2 role (minter/burner/upgrader/admin), the LP NFT, and receives settlement + fee flows. 3 keeps signing latency low (execution window is 7d); 2/3 tolerates one lost key. Addresses must be confirmed in the SUR-662 signer-configuration thread, never pasted into chat from memory. |
| B2 | `threshold` | **2 of 3** | Kit + rehearsal precedent (3 owners, threshold 2). 2/3 = one lost key doesn't strand the launch; a single key can never move funds. |

## C. Token — `token.*` (3 TBDs)

| # | Param | Recommendation | Why |
|---|---|---|---|
| C1 | `name` | **SURPLUS** (unchanged from v1) | 1:1 migration; keeping the name avoids holder confusion. (Alternative: "Surplus Intelligence" if rebranding is wanted — flag if so.) |
| C2 | `symbol` | **SURPLUS** (unchanged) | Same. |
| C3 | `capWei` | **100,000,000,000 × 10¹⁸ — exactly v1 totalSupply at the pin (verified 100B on-chain, block 51935583)** | 1:1 flat migration ⇒ the cap must be ≥ 100B + LP-budget headroom. Capping at exactly v1's supply is the honest maximum: nothing can ever be minted beyond the migrated supply + explicitly-budgeted LP seed (the batch mints backing+budget and the cap rejects anything past it). A larger cap invites "why?" at review; exactly-100B is self-justifying. NOTE: `capWei` interacts with the LP budget math — the kit computes backing (100% of committed) + v2 seed budget; if cap == totalClaimable exactly, the seed budget won't fit. Recommend **cap = 100.1B** (0.1% LP headroom over v1 supply) so backing + seed + tiny reserve fits without a future cap raise (cap can only be changed by upgrade). |

## D. Hook fee recipient — `hook.feeRecipient` (1 TBD)

| # | Param | Recommendation | Why |
|---|---|---|---|
| D1 | `feeRecipient` | **The launch Safe** (same address as B1) | Default precedent (settler's §6.4 rehearsal default is the Safe). Fees accumulate in the hook; the TREASURY-only withdraw paths move them to the Safe for governed spend. A separate treasury Safe is cleaner long-term but adds B1-sized signer setup now; can be changed later ONLY by redeploying the hook — so if a separate fee treasury is ever wanted, decide before deploy. **This one is genuinely one-way.** |

## E. Operators — `operators.*` (2 TBDs)

| # | Param | Recommendation | Why |
|---|---|---|---|
| E1 | `deployer` | **A fresh throwaway key used ONLY for CREATE2 deploys, gas swept from the smoke wallet** | The smoke wallet (prod e2e owner) already holds 9.0 Base Sepolia ETH (nonce 0, verified 2026-10-09) — no faucet needed; the testnet exercise needs <1 ETH total. Fresh key keeps testnet activity isolated and holds NO role afterwards (the token init grants everything to the Safe). |
| E2 | `relayer` | **A dedicated operational EOA (e.g. the existing ops wallet) that executes push batches** | `push_plan.py` sends the Multicall3 batches from this key. It can NEVER redirect payouts (claims pay the leaf's account), only front gas. Any EOA works; dedicated keeps the journal attribution clean. |

## Decided already (do not re-litigate — recorded here for completeness)

- claimPeriod = 0 (claims never expire) — Bill 2026-09-29
- Chain = Base — Bill 2026-09-24
- Ratio = 1:1 flat, PRO_RATA_ENABLED — Bill 2026-09-28
- Launch order = pool-first single batch — Bill 2026-09-28
- Hook fee 1.5% (150 bps) split 0.75/0.75 — params already carry it
- Bridged holders: no special outreach — Bill 2026-09-29
- Rival-pool depth alert $125k — Bill 2026-09-29
