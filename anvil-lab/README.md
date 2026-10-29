# SURPLUS: actual-hook discovery and Anvil comparison lab

**Local fork testing only. Do not deploy the executor to a live chain.**

This package is intended to answer two different questions:

1. Does the real hook on this SURPLUS pool permit adding and removing a WETH-funded position at lower human SURPLUS prices?
2. With the same starting SURPLUS and WETH, does that position increase **net WETH recovery**, rather than simply returning WETH that the experiment supplied?

## Validation status — read first

**The real hook address has NOT been observed by the author. No live Base fork result is included.** Explorer/RPC access and compiler downloads were unavailable in the authoring environment. Python regression checks and shell/Python syntax checks passed; **the Solidity has not been compiled or executed here**. Compile and run the included offline Solidity smoke tests before the fork tests. Treat any compilation error as a harness issue, not a pool result.

`reports/offline-validation.txt` contains the actual local Python results. Synthetic fixtures in the offline tests are explicitly not evidence about SURPLUS's deployment.

## Scope and identifiers

| Item | Value |
|---|---|
| Network | Base, chain ID 8453 |
| SURPLUS | `0xc52aedec3374422d7510e294cfaa90799595cba3` |
| WETH | `0x4200000000000000000000000000000000000006` |
| Pool ID | `0xfc25fdd217e288d03a877f0b7d49e0bbe52b2288c88de929125062569fc7eb2a` |
| PoolManager | `0x498581ff718922c3f8e6a244956af099b2652b2b` |
| StateView | `0xa3c0c9b65bad0b08107aa264b0f3db444b867a71` |
| PositionManager | `0x7c5f5a4bbd8fd63184577525326123b519429bdc` |

The deployment addresses are from Uniswap's official Base deployment table. The pool ID and token are the migration's working identifiers. Discovery must recover an Initialize event whose complete PoolKey hashes to that ID and whose currencies match. It refuses to guess a hook from Bankr branding or the current launch documentation.

**This tests the current entire pool. It does not remove existing third-party positions or assert that they are all locked.** Testing “only the Bankr-locked position remains” requires a separate, verified position-owner inventory and legitimate withdrawal paths for the removable positions. Do not edit PoolManager storage to manufacture that scenario.

## Prerequisites

Use Linux or macOS, Python 3.10+, current Foundry (`forge`, `anvil`), and a **Base archive RPC** with historical storage and historical log access. No private key, funded wallet, seed phrase, wallet connection, or live-chain approval is needed.

Official Foundry installation: <https://getfoundry.sh/introduction/installation>

The Python scripts use only the standard library. Foundry downloads Solidity 0.8.26 on first build. There are no floating Solidity library dependencies.

```bash
unzip SURPLUS_anvil_lab.zip
cd SURPLUS_anvil_lab
python3 scripts/test_offline.py
forge build
forge test --match-contract MathSmokeTest -vv
```

The three Solidity smoke tests check integer math and native-range asset orientation. They are not hook tests.

## 1. Discover the actual hook, using read-only Base RPC calls

```bash
export BASE_RPC_URL='https://YOUR_BASE_ARCHIVE_RPC'
python3 scripts/discover.py
```

Keep the RPC URL private; providers commonly embed API credentials in it. The script does not save the URL. RPC reads consume your provider's request allowance but no on-chain gas.

By default the pin is the provider's head minus 20 blocks. This is a repeatable near-head snapshot, **not a claim of finality**. To choose a block explicitly:

```bash
python3 scripts/discover.py --block 12345678   # replace with an appropriate Base block
```

Discovery:

- Cross-checks core slot0 against the deployed StateView.
- Binary-searches historical initialized state to find the pool's initialization block, rather than scanning millions of log blocks.
- Retrieves the actual Initialize event and verifies its PoolKey hash.
- Reads the hook runtime and Keccak hash at the pin.
- Decodes the address-encoded hook permission flags; probes a few optional getters and EIP-1967 proxy slots.
- Saves `reports/discovery.json`, `reports/initialize-log.json`, `reports/hook-runtime.hex`, and public constants in `.env.fork`.

An archive provider is needed for the binary search. A provider that silently substitutes current state for historical reads will normally fail the event/hash cross-check. If the true Initialize block is already known, `--init-block NUMBER` skips the search. `--init-log PATH` accepts a saved log, but still verifies that event with the RPC. Do not insert a hook address manually to make a failed discovery pass.

**Flags identify enabled callbacks; they do not identify all the conditions or fees implemented by those callbacks.** An unsupported `owner()` getter is not a prohibition on adding liquidity. Zero EIP-1967 slots do not rule out other delegation designs.

## 2. Start a pinned Anvil fork — terminal A

From the same directory:

```bash
source .env.fork
anvil \
  --fork-url "$BASE_RPC_URL" \
  --fork-block-number "$FORK_BLOCK" \
  --chain-id 8453 \
  --host 127.0.0.1 \
  --port 8545
```

Keep it running. Preserve Base chain ID 8453 so chain-dependent code is not silently given a different ID. Bind only to loopback. Do not import real wallets into Anvil or use Anvil's public test keys anywhere with real funds.

No broadcast commands are included. The harness later runs `forge test` against the local Anvil snapshot; mutations occur inside each isolated test VM. Anvil's upstream connection fetches state, not submitted migration transactions.

## 3. Run the permission probes — terminal B

```bash
cd SURPLUS_anvil_lab
./run.sh probe
```

The wrapper sources the discovered public constants, checks that the endpoint is a loopback Anvil with the pinned chain/block/hash, and saves timestamped logs and a non-secret settings manifest.

| Test | What it attempts |
|---|---|
| `test_00_metadata_and_core` | Read current core state; reconstruct aggregate principal across all initialized ranges. |
| `test_01_direct_add_then_remove` | Add and remove a lower-human-price position via a small custom PoolManager callback. |
| `test_02_position_manager_add_then_remove` | Add and remove the same position through the actual deployed Uniswap PositionManager. |

The default LP budget is **0.001 simulated WETH**, plus a separately accounted 1-WETH buffer. It is created by injecting ETH into the local test actor and wrapping it normally; it is not real ETH. The buffer allows accounting deltas to be observed, but cannot fund an arbitrary additional token-denominated hook charge. A failure must be inspected in the trace.

The default range starts roughly ten times below the current SURPLUS price and extends to roughly twenty times below it, subject to tick alignment. **Native tick increases when SURPLUS is sold**: WETH is currency0 and SURPLUS is currency1, so the native ratio is SURPLUS/WETH, the reciprocal of the usual WETH-per-SURPLUS price. The test validates this currency order and refuses a range on the wrong side.

A failed test is not automatically “the hook forbids LP.” Inspect which call reverted. Possible causes include hook restrictions, missing hookData, a route-specific restriction, insufficient assets for hook charges, an interface mismatch, RPC failure, or a harness defect.

## 4. Supply a finite, existing SURPLUS inventory for the sale comparisons

Edit `donors.json` with addresses of **ordinary externally owned accounts holding SURPLUS at the pinned block**, for example:

```json
{
  "addresses": [
    "0xREPLACE_WITH_A_REAL_40_HEX_CHARACTER_HOLDER_ADDRESS"
  ]
}
```

The placeholder is deliberately invalid: replace it rather than run it literally. Multiple EOA holders can be listed. The test transfers up to the requested quantity from their existing fork balances, checks exact balance changes, and checks that total supply did not change. It neither mints nor uses a storage override for SURPLUS. PoolManager, the hook, zero addresses, and contract custodians are rejected as donors.

Impersonation is confined to a fork test. Being able to simulate a transfer is **not evidence of that holder's consent, your custody, or an executable live migration**. Count only actually committed holder assets when drawing practical conclusions. Smart-wallet/custodial balances need a reviewed transfer mechanism; the initial harness intentionally does not impersonate contracts or their privileged owners.

## 5. Compare the three strategies with identical starting assets

Start small enough to be covered by the donor list:

```bash
SELL_TOKENS=1000000 \
LP_WETH_BUDGET_WEI=1000000000000000000 \
./run.sh compare
```

That models one million old SURPLUS and a one-WETH LP budget. Each of the three tests starts from an isolated copy of the same pinned state, with the same SURPLUS inventory and WETH seed.

| Mode | Test | Sequence |
|---|---|---|
| 0 | `test_20_direct_sale` | Sell the committed inventory directly. |
| 1 | `test_21_add_sell_remove` | Add the lower-price LP, sell the inventory, then remove the new LP. |
| 2 | `test_22_add_sell_remove_resell` | Same as mode 1, then attempt one additional sale of all remaining/returned SURPLUS. |

Mode 2 prevents an incomplete comparison from overlooking tokens returned by the temporary position. It is one explicit re-sale, not an unbounded recycling loop.

When the PositionManager probe succeeds and the custom route does not, use:

```bash
USE_POSITION_MANAGER=true \
SELL_TOKENS=1000000 \
LP_WETH_BUDGET_WEI=1000000000000000000 \
./run.sh compare
```

This switches the LP add/remove route; swaps still use the custom callback. A sender-restricted swap requires a separate, reviewed router path. The trace should identify that rather than bypassing the restriction.

Larger examples, only when donors cover the requested inventory:

```bash
for amount in 100000000 1000000000 10000000000 50000000000; do
  SELL_TOKENS="$amount" LP_WETH_BUDGET_WEI=1000000000000000000 ./run.sh compare
done
```

Do not call any quantity “100% participation” without reconciling current eligible supply and custody. An insufficient-donor failure is not a swap-liquidity limit.

### Alternative range and budget settings

```bash
RANGE_GAP_TICKS=46000 \
RANGE_WIDTH_TICKS=7000 \
SELL_TOKENS=1000000000 \
LP_WETH_BUDGET_WEI=5000000000000000000 \
./run.sh compare
```

This starts roughly 100 times below the current human price; the default 23,000-tick gap is roughly ten times below. Both are aligned to the actual pool tick spacing. Gaps/widths are experimental choices, not a recovery recommendation.

| Environment variable | Meaning |
|---|---|
| `SELL_TOKENS` | Whole SURPLUS tokens; default 1,000,000. |
| `SELL_AMOUNT_RAW` | Exact raw token units; overrides `SELL_TOKENS`. |
| `LP_WETH_BUDGET_WEI` | WETH used to size the added position; default 10^15 wei. |
| `RANGE_GAP_TICKS` / `RANGE_WIDTH_TICKS` | Positive native-tick offsets, rounded to spacing. |
| `RANGE_TICK_LOWER` / `RANGE_TICK_UPPER` | Exact native ticks, overriding calculated endpoints. Must be valid, aligned and on the lower-human-price side. |
| `SQRT_PRICE_LIMIT_X96` | Optional sell limit; must exceed current native sqrtPrice and be below the core maximum. Default is MAX_SQRT minus 1. |
| `USE_POSITION_MANAGER` | `true` switches LP operations to deployed PositionManager. |
| `ADD_HOOK_DATA` / `SWAP_HOOK_DATA` / `REMOVE_HOOK_DATA` | Hex bytes, default empty; only set after reviewing the real hook requirements. |

A high diagnostic gas allowance and broad price limit are intentional **test parameters**, not production execution bounds. These contracts have no production minimum-output guarantee.

## 6. Read results correctly

The primary comparison is:

```
net_weth_recovered_wei = actor WETH at end - actor WETH at start
```

The start balance includes the **entire** self-funded WETH seed, not just the amount added to the LP. Thus the result cannot label that supplied seed as recovery. Gas, Base L1 costs and market MEV are not subtracted; output is before those execution costs.

Also compare:

- `surplus_left_final_raw` and `net_surplus_spent_raw` — same initial tokens does not mean both routes consumed the same quantity.
- `lp_add_weth_cost_wei` and `first_swap_weth_received_wei` — gross receipts versus supplied capital.
- `before_core_weth_principal_wei` / `after_core_weth_principal_wei` — reconstructed aggregate core principal, not manager-wide token balances.
- `surplus_returned_by_lp_removal_raw` — important when selling into your own LP.
- `before_native_tick` / `after_native_tick` — lower human price corresponds to higher native tick here.
- `hook_weth_wallet_delta_wei` — a diagnostic balance change, **not a complete measurement of all hook/protocol fees**.
- `execution_gas_diagnostic_excludes_initial_funding_and_reserve_scan` — comparative instrumented gas, not a production gas limit or total Base fee estimate.

The lens scans every bitmap word for the pool's spacing and rebuilds its liquidity intervals. It rejects a nonreconciling curve. Rounding per reconstructed interval can differ by dust from summing individual position withdrawals. It excludes accrued fees, hooks' off-curve balances, ERC-6909 credits and other accounting not represented by core principal. Never infer “ETH lost” merely by subtracting net receipts from initial core principal.

The complete scan can require many historical RPC storage requests, especially at narrow tick spacing. It is not an operation the migration executor needs to run on-chain. A diagnostic out-of-gas or provider rate limit is not proof the migration cannot execute.

## Interpretation table

| Observed result | Interpretation |
|---|---|
| Both add/remove routes succeed | Those positions are permitted for the tested callers, range, size, state and hookData. Not proof of universal permission. |
| Custom add fails; PositionManager succeeds | Route matters. Repeat comparisons with PositionManager LP operations. |
| Both add routes fail inside a hook callback | Inspect the revert and exact hook source; a restriction is plausible but still distinguish missing data/assets. |
| Added-LP route has more gross output but the same/lower net WETH | Some/all extra output was self-funded or paid for through losses elsewhere. |
| Mode 1 is worse but mode 2 catches up | Returned tokens needed to be resold for a fair comparison. |
| Added-LP route appears to improve net WETH | Reconcile fees, leftover tokens, all remaining positions, hook balances and gas before interpreting it as a recovery improvement. |
| Price moves farther but original core WETH does not decrease more | Lower displayed price is not additional original-capital recovery. |
| Sale leaves tokens unspent | A price limit/range endpoint or another constraint may have bound; examine the trace and remaining principal. |

## What is not yet proved

This lab does not prove permanent locking, beneficial ownership, a locked-only pool configuration, maximum feasible migration participation, fee-recipient controls, upgrade safety, hook liveness across time, or safe mainnet execution. It does not model competing traders/MEV, daily fee changes, or staged blocks. All operations in a scenario run in one test transaction's block environment. A production transaction still requires routing review, net-output bounds, gas feasibility and an independently reviewed migration contract.

The actual hook source and any nested delegate/extension calls must be reviewed after discovery. Runtime hashes pin evidence but do not replace source review. A current explorer source listing can also be insufficient when implementations changed after the pinned block.

## Files to return

Send `reports/discovery.json` and the timestamped `reports/probe-*.txt` plus its `*-settings.json`. Then add the relevant `reports/compare-*.txt` and settings manifests when comparisons run.

Do not send the RPC URL, API keys, private keys, `.env` files containing secrets, or Anvil startup output. Traces contain public donor addresses and any hookData you used; review them before sharing. The manifest hashes donor input instead of publishing the donor list, but the verbose test trace can still display transfers.

If compilation fails, return the compiler output and `forge --version` rather than treating it as hook evidence. If discovery fails, return the sanitized STOP message and provider capability description, not its credential-bearing URL.

See `SOURCES.md` for official technical references and `NOTICE.md` for code attribution.
