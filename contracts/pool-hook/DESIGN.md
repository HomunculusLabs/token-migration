# DESIGN.md — successor-pool hook

**Status: local draft, NOT approved for deployment.** Nothing here has been deployed or broadcast. The tests use
throwaway initializer addresses and a mock v2 token; they are not launch parameters.

`SurplusPoolHook` is a Uniswap v4 hook for exactly one pool, the official successor pool: **v2/WETH, 1.2% LP fee
(12,000 pips), the tick spacing given at deployment (60), hooks = this contract**. Its only job is to make sure the
launch contract, and nobody else, creates that pool. It charges no fee. Native-ETH pools are out of scope.

## Fees

The pool has one fee: its static **1.2% LP fee**, set in the pool key and charged by the PoolManager on every swap's
input. It accrues to the pool's liquidity positions, all of which the launch mints to the Safe, and the Safe collects
it through the PositionManager like any LP. Nothing goes to the hook: there is no hook fee, no team or buyback
split, and no hook withdrawal.

Anyone who later adds liquidity to the same pool earns a share of the 1.2% in proportion to their in-range
liquidity. Fees go to whoever provides the liquidity, not to a fixed recipient.

## What the hook enforces

### 1. Permissions: initialization only

The PoolManager reads a hook's permissions from the low 14 bits of its address. The constructor requires those bits
to be **exactly** `0x2000` = `BEFORE_INITIALIZE`:

- Without `BEFORE_INITIALIZE`, the gate below would silently never run.
- Any other bit would have the manager call the hook on swaps, liquidity changes or donations.

So the PoolManager calls the hook once, when the pool is created, and never again. Swaps and liquidity changes on
the official pool cost the same and return exactly the same amounts as on a pool with no hook. The fork suite proves
both: every swap shape matches a hookless twin pool to the wei, and with the hook's code replaced by an instruction
that always reverts, swaps and liquidity changes still go through.

### 2. The gate: one pool, one initializer

`beforeInitialize` reverts unless all three hold:

- the caller is the PoolManager;
- `sender == INITIALIZER`, the launch helper;
- the key equals the official key: `CURRENCY0`, `CURRENCY1`, `LP_FEE`, `TICK_SPACING`, and `hooks == address(this)`.

Without the gate, anyone could initialize the official key first, at a price of their choosing. The launch's own
`initialize` would then revert and the launch could not run until a new hook and key were deployed. With the gate,
the official pool can exist only when the initializer creates it, inside the launch transaction. No other pool can
use this hook, whatever field it differs in (fee, tick spacing, currencies, native ETH).

The constructor also rejects:

- a zero PoolManager or initializer, which would brick the hook;
- a zero currency, which means native ETH and is out of scope;
- `currency0 >= currency1`, a key that v4 can never initialize;
- an LP fee above 1,000,000 pips. That covers v4's dynamic-fee flag (`0x800000`): a dynamic-fee pool opens at 0%
  and only its hook can set the fee, which this hook never does, so the pool would trade for free.

Every launch parameter is an **immutable**: `POOL_MANAGER`, `INITIALIZER`, `CURRENCY0`, `CURRENCY1`, `LP_FEE`,
`TICK_SPACING`. They therefore live in the runtime code. The launch helper reads `INITIALIZER()` and requires it to
be its own address. A test etches a copy of the runtime to an empty address and proves every getter and the gate
still work.

## Authority table

| Function | Who can call | Constraint |
|---|---|---|
| `constructor(...)` | whoever deploys (CREATE2 via Arachnid's proxy at a mined salt) | address flag bits exactly 0x2000; no zero addresses; currency0 < currency1; LP fee ≤ 1,000,000 |
| `beforeInitialize` | PoolManager only | sender == INITIALIZER **and** key == official key |

There is no owner, no admin, no pause, no upgrade path, no setter and no custody. The hook holds no tokens and has
no `receive()`; tokens sent to it by mistake cannot be recovered. The initializer and key are fixed for the life of
the hook. Changing either means a new hook, and therefore a new pool.

## What is deliberately NOT encoded

- **Rival venues cannot be prevented on-chain.** The gate stops other pools from using *this hook*. It cannot stop
  anyone from creating a hookless v4 pool, a v3 pool or a CEX market for v2/WETH, at any fee.
- **Initialization price.** The gate controls who initializes, not at what price. The launch helper initializes,
  adds liquidity and asserts the price in one transaction.
- **Who earns the LP fee.** It goes to in-range liquidity. The launch's positions are the Safe's; anyone can add more.

## Verification

| Evidence | Where |
|---|---|
| Exactly the BEFORE_INITIALIZE bit; constructor checks; the gate rejects every caller, sender and key but the official one; no swap or liquidity callback exists | `test/SurplusPoolHook.t.sol` |
| Every swap shape on the official pool matches a hookless twin to the wei, both currency orders; exact-output swaps of 99% of either side settle; swaps and liquidity changes never call the hook; a small trade costs the 1.2% LP fee and nothing else; the position owner collects 1.2% of each trade's input | `test/fork/SurplusPoolHookFork.t.sol` against the real Base PoolManager at block 51,935,583 |
| Only the initializer can create the official pool; no other key can name the hook | `test/fork/PoolGateFork.t.sol` |
| The hook deployed through the live CREATE2 proxy at a mined salt | `ForkHarness._deployHookViaCreate2` |
| The salt miner deploys to the predicted address and passes the flag check | `test/MineHookSalt.t.sol` |

The fork suite proves the contract against the real PoolManager on a local fork. It does **not** prove a mainnet
deployment, the Safe's configuration, or the launch helper's batch. Those are separate rungs.

## Launch parameters

The launch kit (`contracts/migration-launch/kit/`) supplies the constructor arguments: v2 and the initializer (the
settler) are addresses its deploy plan derives; the LP fee (12000) and tick spacing (60) come from `params.json`
`successorPool`, pinned identically in the settler. No hook parameter is an open decision.

The previous design, `SurplusFeeHook`, also took a 1.5% swap fee split between a team half and a buyback half. It
was dropped before launch; the dated reviews and rehearsal evidence under `contracts/migration-launch/kit/evidence/`
and `docs/` describe it.
