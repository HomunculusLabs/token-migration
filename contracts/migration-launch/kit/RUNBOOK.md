# SURPLUS v1 → v2 launch: runbook

The launch-day sequence, who signs what, and every abort path. Commands run from
`contracts/migration-launch/`. Each kit phase prints what it wrote and stops loudly on any problem or
open decision. **No kit phase broadcasts to Base.** Safe simulations and explicit rehearsal helpers send
transactions only to an isolated loopback Anvil. Real-chain transactions come only from the deployer,
the Safe signers and the relayer, as listed.

Before anything, `kit/params.json` must have no `TBD` left (spec §6). `python3.14 kit/launch.py check`
lists the open decisions. After a decision is ratified, update the corresponding `check.py` SPEC_6/DECIDED
entry and regenerate the reviewed manifest; filling the JSON alone deliberately fails the old decision gate.
Production parameters have `mode: "production"`; `--rehearsal` loads the explicit rehearsal-mode file.
Never copy rehearsal signers or keys into a production packet.

## Who does what

- **Deployer (one EOA, §6.7):** sends the six deployments. After step 1 it holds no role anywhere; the
  dry run checks that.
- **Safe signers (§6.1, threshold M of N):** sign two Safe transactions, `commitRoot` and the launch batch.
  Later, fee withdrawals and any rescue.
- **Relayer (one EOA, §6.7):** sends the push batches. It can only pay leaves to their own accounts, so it
  needs no trust.
- **Anyone:** can deposit, claim for themselves, relay a claim, and trigger the timeouts.

## The sequence

### 1. Deploy (deployer)

```
python3.14 kit/launch.py deploy-plan --rpc <Base RPC>
```

This prints every address and writes `kit/output/deploy/`: `plan.json` (init code and salts),
`basescan.json` (verification commands) and `deployment.json`. It first replays all six deployments on a
fork of the RPC and checks each against the decided settings.

The deployer then sends, in this order:
1. the Safe: `SafeProxyFactory.createProxyWithNonce(singleton, <safeInitializer from plan.json>, saltNonce)`
2. the v2 implementation
3. the v2 proxy
4. the vault
5. the settler
6. the hook

Steps 2–6 are each one call to the CREATE2 deployer `0x4e59…956C` with data = `salt ‖ init code` (both
in `plan.json`).

Then:
- Re-run `deploy-plan`. Every address now has code, so the dry run re-checks the real contracts in place.
- Verify each contract on Basescan with the commands in `basescan.json`.
- Publish the addresses (HOLDERS.md).
- Record the vault's deploy block: the `blockNumber` of its deployment receipt. The snapshot scans from it
  (`--from-block`), so it does not depend on how much history the launch-day RPC keeps.

If a deployment lands anywhere but its planned address, stop: the inputs differ from the plan.

### 2. Deposit window (holders)

Holders approve and deposit v1 until `depositDeadline`. They can withdraw until the deadline. From the
deadline on, the ledger is frozen: it cannot change again unless the migration is cancelled.

### 3. Snapshot and root (anyone builds it, the Safe commits it)

The snapshot finds depositors through `eth_getLogs` pages of `--log-chunk` blocks and stops past 10,000
pages. Its default page, 10 blocks, covers 100,000 blocks: about 2.3 days of Base's 2-second blocks. A
30-day window is about 1.3M blocks, so it needs pages of at least 130 blocks from an RPC that serves ranges
that wide. `snapshot-plan` sizes the pages and proves the RPC can serve them before the snapshot starts.

**Before deposits open, and again before the deadline,** probe the RPC you will launch with:

```bash
export KIT_RPC_URL=…   # a paid Base archive RPC, supplied privately; never echo it or put it in evidence
python3.14 kit/launch.py snapshot-plan --probe --window-days 30
```

It runs the snapshot's own depositor scan over the most recent 30 days of Base, then checks archive state,
push-plan's page size and call latency. Launch on an RPC that prints `OK`. The team's free-tier Alchemy key
fails (it serves 10-block pages; `evidence/kit/snapshot-plan.txt`). The kit sends Python's default
User-Agent, which most public Base RPCs, `mainnet.base.org` included, refuse with HTTP 403; the probe's
first call shows that.

**After `depositDeadline`:**

```bash
python3.14 kit/launch.py snapshot-plan --vault <vault> --from-block D --run
```

`D` is the vault's deploy block, recorded in step 1. The plan picks N, the newest block Base has finalized.
N must come after the deadline; until then the plan exits 3 and says when to retry. It sizes `--log-chunk`
(the smallest that fits 10,000 pages, raised to 2,000 when the RPC serves that), runs the snapshot's
depositor scan over the whole window, prints the snapshot command, and says how long the snapshot will take
and how much commit window is left. `--run` then runs the snapshot. Without `--run`, run the printed
command, where `C` is the page size the plan chose:

```
python3.14 kit/launch.py snapshot --block N --vault <vault> --from-block D --log-chunk C
```

Record N and its hash from the archive RPC; a local Anvil's `finalized` tag is not proof of Base finality.

The snapshot reads every depositor from the vault's own logs and each one's ledger at N. It stops unless the
sum equals the vault's on-chain total. It builds the tree, then verifies it three ways (VerifyTree,
VerifyTreeBulk, an independent Python rebuild).

It reads each depositor's ledger twice, one call at a time: at the 130–150 ms per call measured on Base
(2026-10-24), 6,000 depositors take about an hour. `safe-txs commit-root` and every `push-plan` run read
each leaf again, about half as long. `commitRoot` must execute before `commitDeadline`, so the commit window
has to hold the snapshot, a second person's rebuild, the commit-root packet and signing. The 7 days the
decision brief proposes (A3) leave room; a few hours do not. Past the deadline, the only way out is
`expireCommit` and refunds (abort paths below).

Output: `kit/output/snapshot/N/` with `tree.json`/`tree.csv`, the root, the total and the `commitRoot`
calldata. Any second person should rebuild it and compare the root and sha256s; the result is
byte-identical by construction. Keep `snapshot.json` beside the tree, including its chain, vault, block
hash and file hashes. Independently verify every account against the frozen ledger; matching only the
root and total is insufficient.

Start a **fresh private simulation fork** in a separate terminal before either Safe preparation step:

```bash
# BASE_RPC_URL is supplied privately in the shell; never put its value in evidence.
PIN=$(cast block-number --rpc-url "$BASE_RPC_URL")
anvil --host 127.0.0.1 --port 18560 --chain-id 8453 --fork-url "$BASE_RPC_URL" --fork-block-number "$PIN" --silent
```

Verify the fork's chain ID, block number and hash against the same Base block. Safe simulations never
replace this independent origin check. Recreate the fork after the real root transaction confirms and
again whenever preparing a replacement launch transaction. Do not reuse a mutated rehearsal server.
`K` and `K+1` below mean the actual integer nonces, not literal command arguments.

```
python3.14 kit/launch.py safe-txs commit-root --deployment kit/output/deploy/deployment.json --tree kit/output/snapshot/N/tree.json --safe-nonce K --rpc http://127.0.0.1:18560 --canonical-rpc <Base archive RPC>
```

The Safe signers import the Transaction Builder JSON, check it against SIGNER-CHECKLIST.md and sign.
`commitRoot` must execute before `commitDeadline`.

### 4. The launch (Safe signers): one contract, one atomic transaction

```
python3.14 kit/launch.py safe-txs launch-batch --deployment kit/output/deploy/deployment.json --safe-nonce K+1 --rpc http://127.0.0.1:18560
```

Simulate-then-sign:
1. The kit runs a launch contract with no floor and the whole remaining cap as budget on a fork of the latest
   block, and records what it raised and used.
2. It signs `minWethOut` = simulated WETH × 0.995 and the v2 budget = simulated v2 + 10 wei. The v2 side is
   fixed by the signed ranges, not by the sale, so the budget needs no drift margin.
3. It deploys the launch contract with those numbers and runs the exact signed transaction, which must succeed.

The launch is one contract, `src/MigrationLaunch.sol`, built for these numbers, and one Safe transaction: a
DELEGATECALL to its `launch()`. Signers read every number on the contract itself (SIGNER-CHECKLIST.md). It
runs five steps as the Safe:
1. `v2.mint(vault, total)`
2. `vault.activateClaims()`
3. `vault.withdrawV1ForSettlement(settler, total)`
4. `v2.mint(settler, budget)`
5. `settler.settle(params)`

It then checks the result and that the Safe's owners, threshold, modules, guard, fallback handler and
singleton are unchanged, and reverts everything otherwise. It has no storage of its own and runs only at this
Safe.

**Deploy it before the Safe transaction executes.** Send `send` from `launch-batch.deploy.json` from any
funded account: it is a CREATE2 deployment through the deterministic deployer, so its address follows from the
code and the numbers, and anyone sending it gets the same contract. Then check that the code at
`launchContract` hashes to `runtimeCodeHash`, verify the source with the file's `verify` command, and queue the
Safe transaction. A Safe DELEGATECALL to an address with no code succeeds and does nothing: it spends the nonce
and launches nothing (`test/fork/MigrationLaunch.fork.t.sol::test_NoCodeAtTheTargetIsASilentNoOp`).

`settle` sells the v1 on the Doppler pool and the v3 1% tail. It then opens the v2/WETH pool (0.30% LP
fee + the 1.5% hook) at v1's pre-sale tick rounded to the 60-tick grid, and seeds it with two single-sided
sides that meet at that tick (SUR-658, decided 2026-10-25):
- the v2 side: signed ranges that copy the v1 the old pool still offered above its price at simulation
  time, the same amounts over the same ranges, paid from the v2 budget;
- the WETH side: one position from the opening tick to the end of the range, holding all the WETH raised.
Every LP position is minted to the Safe; leftovers go back to the Safe.

Claims and the pool go live atomically. The opening price is the simulation-time price signed in the
batch, not a guarantee of execution-time market spot or realizable holder value. Execute promptly:
proceeds below the signed floor revert the entire batch. Price drift cannot push the v2 side past its
budget, because the signed ranges alone set it. The floor bounds proceeds; it is not a direct 0.5% spot-price
guard. Re-simulate and re-sign if needed.
Read `rootCommittedAt()` after the real commit; activation must occur no later than
`rootCommittedAt + EXECUTION_WINDOW`. A missed window requires cancellation/refunds, not late activation.

After execution, check (the settler exposes these):
- `settler.wethRaised() ≥ minWethOut`
- `settler.positionCount()` = v2 ranges + 1, and every LP NFT from `settler.firstPositionId()` on is owned
  by the Safe
- `vault.claimsActive()` is true
- the settler holds no tokens

### 5. Push distribution (relayer)

```
python3.14 kit/launch.py push-plan --tree kit/output/snapshot/N/tree.json --deployment kit/output/deploy/deployment.json --rpc <Base RPC>
```

This writes immutable Multicall3 `aggregate3` plans under `kit/output/push-plan/plans/<id>/`, each batch
under 128 KB of calldata and 2^24 gas, plus the current summary `plan.json` and a cost estimate. The
relayer sends the reviewed batch files in order. Keep the original plan, file hashes and transaction
receipts; a later completion plan must not replace that evidence.

Rerun `push-plan` against Base after each confirmed group and after interruptions. It reconciles both
`ClaimPaid` and `ProRataClaimed` events to each entitlement, the bitmap and `totalClaimedAmount` at a pinned
head. Completion means `status: complete` and `toPush: 0`, not merely successful outer receipts.
A successful Multicall transaction may contain failed inner calls; resolve every unpaid exception.
`push-plan` scans payouts from the snapshot block in pages of `--log-chunk` blocks (default 1,000), at most
10,000 pages: 10M blocks, about 231 days. An RPC that serves only 10-block pages covers about 2.3 days of
claims; `snapshot-plan --probe` reports what yours serves. A missing or
truncated history is an error, never evidence that an account is unpaid or paid.

The loopback-only rehearsal executor stores `executions/` journals and `progress.json`. After a crash,
use `--resume-plan <immutable plan.json>` with the same tree, parameters and explicit rehearsal execution
flags. `--execute-first N` always selects the original plan's first N batches, not the next N; repeat the
original N to recover that prefix, or increase it to continue. Already-paid batches are not sent again;
a new invocation can record a no-send reconciliation observation. An ambiguous submission keeps
attribution unknown; independently reconciled payments still count.
Production broadcasting stays with the relayer, not this helper. Replans never pay someone twice, and
`claim()` pays the leaf's account, never the sender. Self-claim remains the fallback.

### 6. After launch (Safe)

- Claims never expire (P5: `claimPeriod = 0`), so there is no expiry to run. `sweepResidual` can only
  ever take v2 above what is still owed.
- Watch every rival pool for the pair. Alert at $125k of in-range depth (REPORT.md, siphon table). The
  launch seed is the sale proceeds only, with no extra depth.

- The hook accrues 1.5%: 0.75% team, 0.75% buyback, per currency. The Safe withdraws with
  `hook.withdrawTeam(currency, to, amount)` and `hook.withdrawBuyback(...)`.
- The LP NFT is the Safe's.
- A plain v1 transfer to the vault (outside `deposit`) is rescued with `vault.rescueV1(to)`, and only the
  excess above the ledger.

## Abort paths

Every abort leaves every holder whole. None needs a new contract.

- **Someone initializes the successor pool first (front-run).** They can't. The hook's `beforeInitialize`
  admits only the settler and only the official key. Even if that were bypassed, the settler calls
  `PoolManager.initialize` directly, so a pre-initialized pool makes the whole batch revert. Nothing is
  minted, activated, released or sold, and the Safe nonce is unused. Proven in
  `test/fork/MigrationSettler.fork.t.sol::test_FrontRunInitRevertsTheWholeBatch` (with a hook that does not
  gate) and `RealHookLaunch.fork.t.sol` (the real hook).
- **Sale slippage.** If the sale raises less than `minWethOut`, or the seed would need more v2 than the
  signed budget, the whole launch reverts. Nothing moves. Re-run `safe-txs launch-batch` against the new
  state: it builds a new launch contract (a new address) and a new hash. Deploy it, then sign again.
- **The Safe never commits a root.** After `commitDeadline`, anyone calls `vault.expireCommit()`. The
  migration is cancelled, and every depositor gets their exact v1 back through `vault.refund(account)`
  (anyone can call it for anyone, so the relayer can push refunds) or `withdrawV1`.
- **A root is committed but claims are never activated.** After `rootCommittedAt()` + `EXECUTION_WINDOW()` (strictly greater than that timestamp),
  anyone calls `vault.expireExecution()`. It is cancelled, and refunds are paid from the ledger as above.
  This can't happen after activation, because activation latches.
- **A withdrawal after the deposit deadline.** It is rejected (`LedgerWithdrawalsFrozen`), so the ledger
  the root is built from cannot change under it.
- **v1 sent to the vault by plain transfer.** It is not a deposit and is in nobody's leaf. The Safe
  rescues exactly the excess with `rescueV1`.
- **The push stalls halfway.** Nothing is lost. Rerun `push-plan`, which skips paid leaves, or let holders
  self-claim.

## Governance recovery and signer readiness

Before deposits open, record the final owner addresses and threshold, independent signer-device checks,
backup/recovery arrangements, and the person coordinating an incident. The rehearsal's throwaway keys
prove contract mechanics only; they are never production signers.

- **One signer lost or compromised, quorum still available:** pause new signing, independently verify a
  replacement owner/address, and have the remaining quorum authorize the Safe's `swapOwner` operation.
  Verify the owner list, threshold, nonce, modules, guard and fallback handler on chain afterward. Prove
  the old owner cannot authorize a new transaction and the replacement quorum can. The Safe address
  does not change, so token roles and LP ownership must remain at that same address. Rebuild queued
  launch packets after checking their current nonces and deadlines; do not assume old signatures are usable.
- **Quorum unavailable:** a single remaining owner cannot rotate keys or lower the threshold. The
  planned Safe has no recovery module. Restore enough approved signer access through the agreed backup
  process; if quorum is permanently lost, there is no contractual admin back door. LP/admin operations
  freeze, and hook withdrawals freeze too if that Safe is the immutable treasury. Never promise otherwise.
- **Holder exits do not need the Safe:** before activation, the documented permissionless timeout and
  ledger-refund paths remain available. After activation, backed v2 claims remain available without an
  expiry. Do not propose v1 refunds after activation.
- **Upgrade trust:** the Safe can replace the v2 implementation, including its cap/accounting rules.
  Require independent review and a fresh storage-layout/upgrade rehearsal for any future upgrade.

The final go/no-go also needs a tested $125k rival-depth alert with an operator and destination, a
supported-wallet/UI demonstration, and documented fee-withdrawal/buyback procedures. A configured
threshold, a role-gated burn function, and this checklist are not evidence those operations are running.

## Before signing anything

SIGNER-CHECKLIST.md. The short version: the target, the operation, the nonce, every inner call and every
number must match what the kit printed, and the safeTxHash on the signer's device must equal the kit's.
