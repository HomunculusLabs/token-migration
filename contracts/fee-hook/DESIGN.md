# DESIGN.md — SUR-658 successor-pool fee hook

**Status: local draft, NOT approved for deployment.** Nothing here has been deployed or broadcast. The tests use
throwaway treasury/initializer addresses and a mock v2 token; they are not launch parameters.

`SurplusFeeHook` is a Uniswap v4 hook for exactly one pool, the official successor pool: **v2/WETH, 0.30% LP fee
(3000 pips), the tick spacing given at deployment (60 in tests), hooks = this contract**. It charges a **1.5% fee
(15,000 of 1,000,000 pips)** on every swap through that pool, splits the fee into a team half and a buyback half, and
lets only the treasury Safe withdraw either half. Native-ETH pools are out of scope.

## What the hook enforces

### 1. The fee: exactly 1.5% of the unspecified currency

v4 applies a hook's `afterSwap` return delta to the swap's **unspecified** currency. That is the currency whose
amount the swapper did not fix. The hook charges `fee = floor(|unspecified amount| × 15,000 / 1,000,000)` in that
currency. It takes the fee from the manager in the same call and returns `+fee`, so the manager bills the swapper.

| Swap shape | Swapper fixes | Fee currency | Swapper effect |
|---|---|---|---|
| Exact-in buy (WETH in, v2 out) | WETH in | v2 (the output) | receives 1.5% less v2 |
| Exact-in sell (v2 in, WETH out) | v2 in | WETH (the output) | receives 1.5% less WETH |
| Exact-out buy (v2 out, WETH in) | v2 out | WETH (the input) | pays 1.5% more WETH |
| Exact-out sell (WETH out, v2 in) | WETH out | v2 (the input) | pays 1.5% more v2 |

- The base of the fee is the **pre-fee** unspecified amount, i.e. after the pool's own math and LP fee. Charging
  any other currency (the draft charged the output) makes every exact-output swap revert `CurrencyNotSettled` (H1).
- The hook never changes pool math. A hookless twin pool with the same key fields, price and liquidity returns
  the pre-fee amounts, and the fork suite uses one to prove the hook is paid **exactly** the fee on all four shapes.
- **Rounding.** The fee is floored, so it never exceeds 1.5%. A swap whose fee would round to 0 pays nothing and
  moves no tokens.
- **All-in cost.** The 0.30% LP fee stays with the LPs, and the hook fee stacks on top of it. A small trade costs
  `1 − 0.997 × 0.985 = 1.7955%` in total. The fork test measures 1.7956% on a 0.01 WETH buy and a 250 v2 sell:
  0.3001% is LP fee plus price impact, and 1.4999% is the hook fee after flooring.
- `take()` is called **without** `sync()`. A currency left synced makes any native `settle{value:}` later in the
  same unlock revert `NonzeroNativeValue` (H2). That breaks router batches that include an ETH leg.
- **Split.** `teamOwed += fee / 2` and `buybackOwed += fee − fee / 2`, so an odd wei goes to buyback. `totalTaken`
  records the whole fee. All three are tracked per currency, so WETH fees and v2 fees are accounted separately.

### 2. The gate: one pool, one initializer (H3)

The PoolManager reads a hook's permissions from the low 14 bits of its address. The constructor requires those
bits to be **exactly** `0x2044` = `BEFORE_INITIALIZE | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA`:

- Without `BEFORE_INITIALIZE`, the gate below would silently never run.
- Without `AFTER_SWAP_RETURNS_DELTA`, the manager would discard the fee.
- Any extra bit would make the manager call a hook this contract does not implement.

`beforeInitialize` reverts unless all three hold:

- the caller is the PoolManager;
- `sender == INITIALIZER`, the launch helper;
- the key equals the official key: `CURRENCY0`, `CURRENCY1`, `LP_FEE`, `TICK_SPACING`, and `hooks == address(this)`.

Without the gate, anyone could initialize the official key first, at a price of their choosing, and any other pool
could name the hook. With it, the official pool can exist only when the initializer creates it. No other pool,
whether it differs in fee, tick spacing, currencies or uses native ETH, can ever use this hook.

The constructor also rejects:

- a zero PoolManager, treasury or initializer, which would brick the hook;
- a zero currency, which means native ETH and is out of scope;
- `currency0 >= currency1`, a key that v4 can never initialize.

Every launch parameter is an **immutable**: `POOL_MANAGER`, `TREASURY`, `INITIALIZER`, `CURRENCY0`, `CURRENCY1`,
`LP_FEE`, `TICK_SPACING`. They therefore live in the runtime code. The launch helper reads `INITIALIZER()` and
requires it to be its own address. A test etches a copy of the runtime to an empty address and proves every getter
and the gate still work.

### 3. Custody and payout (H4)

The hook holds only ERC-20 fees and has no `receive()`. `_transfer` reverts in three cases:

- the recipient is `address(0)`;
- the currency has no code;
- the call fails, or returns `false`.

A token that returns no data is accepted, USDT-style. The no-code case covers `address(0)`, i.e. native ETH. Without
it, a call to an address with no code "succeeds" and the withdrawal would be booked as paid while nothing moved.

For each currency and each half, `owed − paid` bounds what a withdrawal can pay. `paid` only moves on a transfer
that succeeded. The hook's balance therefore always equals the sum of the unpaid halves. The fork suite checks this
after all four swap shapes, then has the treasury withdraw both halves of both currencies and leave the hook empty.

## Authority table

| Function | Who can call | Constraint |
|---|---|---|
| `constructor(...)` | whoever deploys (CREATE2 via Arachnid's proxy at a mined salt) | address flag bits exactly 0x2044; no zero addresses; currency0 < currency1 |
| `beforeInitialize` | PoolManager only | sender == INITIALIZER **and** key == official key |
| `afterSwap` | PoolManager only | fee = floor(\|unspecified\| × 1.5%) in the unspecified currency |
| `withdrawTeam(currency, to, amount)` | TREASURY (the Safe) only | amount ≤ teamOwed − teamPaid; `to` ≠ 0; currency has code; transfer must succeed |
| `withdrawBuyback(currency, to, amount)` | TREASURY (the Safe) only | amount ≤ buybackOwed − buybackPaid; same transfer checks |
| `recoverExcess(currency, to)` | TREASURY (the Safe) only | pays only the balance above every unpaid fee (tokens sent to the hook outside a swap); same transfer checks. Oracle review, `test/HookOracleReview.t.sol` |

There is no owner, no admin, no pause, no upgrade path and no setter. Fee rate, split, treasury, initializer and
key are fixed for the life of the hook. Changing any of them means a new hook, and therefore a new pool.

## What is deliberately NOT encoded

- **Buyback routing is Safe policy.** The hook only accounts for the buyback half and releases it to the Safe's
  chosen `to`. It does not encode:
  - which venue to buy on (the cheapest net venue is not always this pool);
  - batch size, slippage or deadline;
  - whether the bought tokens are burned. A real burn needs the v2 token to expose one.
- **The team/buyback split is accounting, not custody.** Both halves sit in the hook until the Safe withdraws them,
  and the same Safe authorizes both withdrawals. Keeping the two apart after withdrawal is a Safe-process
  commitment.
- **Rival venues cannot be prevented on-chain.** The gate stops other pools from using *this hook*. It cannot stop
  anyone from creating a hookless v4 pool, a v3 pool or a CEX market for v2/WETH, and trades there pay no hook fee.
  The fee applies only to swaps routed through the official pool. Wallet transfers are untouched.
- **Initialization price.** The gate controls who initializes, not at what price. The launch helper must initialize,
  add liquidity and assert the price in one transaction.
- **No fee on liquidity.** Adding or removing liquidity and donations are not charged; only swaps are.

## Verification

| Evidence | Where |
|---|---|
| H1, H3, H2/H4 regressions, red on the unfixed hook, green after | `evidence/*-red.txt`, `evidence/*-green.txt`; tests prefixed `test_H1_`, `test_H3_`, `test_H2_`, `test_H4_` |
| Exact 1.5% on exact-in and exact-out, both directions, both currency orders; second swap settles; treasury withdraws both halves; all-in cost | `test/fork/SurplusFeeHookFork.t.sol` against the real Base PoolManager at block 51,935,583 |
| The hook deployed through the live CREATE2 proxy at a mined salt | `ForkHarness._deployHookViaCreate2` |
| The salt miner deploys to the predicted address and passes the flag check | `test/MineHookSalt.t.sol` |

The fork suite proves the contract against the real PoolManager on a local fork. It does **not** prove a mainnet
deployment, the Safe's configuration, or the launch helper's batch. Those are separate rungs.

## Open decisions (deployment blockers)

The launch kit (`contracts/migration-launch/kit/`) supplies the constructor arguments: v2 and the
initializer (the settler) are addresses its deploy plan derives, the tick spacing is 60 (the standard
spacing for the 0.30% tier, `params.json` `successorPool.tickSpacing`, pinned identically in the settler),
and the treasury is the hook fee recipient. v2 has a real, role-gated burn (`contracts/token-v2`).

| Decision | Owner |
|---|---|
| Treasury (hook fee recipient; the rehearsal uses the Safe) and the Safe's signer set | Bill/Mac (spec §6.4, §6.1) |
| Buyback venue, cadence and slippage bounds | Bill/Mac (Safe policy; not a deployment blocker) |
| Independent security review of the hook before any Base deployment | Bill/Mac + reviewer |
