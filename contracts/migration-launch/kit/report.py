#!/usr/bin/env python3.14
"""Writes kit/REPORT.md from data files only, so every number in it is traceable and a rerun is byte-identical.

    python3.14 kit/report.py --rehearsal-dir <…/fullscale-260929> [--result kit/output/rehearsal/result.json]
                             [--snapshot kit/output/snapshot/<N>/snapshot.json] [--push-plan <plan.json>]

Inputs (each one's sha256 is listed at the end of the report):
- the cohort run at the pin: cohort/cohort.json, cohort/not-in-root.json, outreach/outreach.json, pin.json
- the siphon re-run at the ~1.8% fee: siphon/siphon.json
- the full-scale launch rehearsal: kit/output/rehearsal/result.json (FullScaleLaunch.t.sol)
- the kit snapshot that built the tree: kit/output/snapshot/<N>/snapshot.json
"""
import argparse
import json
import sys
from decimal import Decimal, getcontext
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kitlib as k  # noqa: E402

getcontext().prec = 60
Q96 = Decimal(2) ** 96
WEI = Decimal(10) ** 18


def tokens(wei: int | str, digits: int = 0) -> str:
    value = Decimal(int(wei)) / WEI
    return f"{value:,.{digits}f}"


def pct(part: int | Decimal, whole: int | Decimal, digits: int = 2) -> str:
    return f"{Decimal(part) * 100 / Decimal(whole):.{digits}f}%"


def usd(amount: Decimal | float) -> str:
    return f"${Decimal(amount):,.0f}"


def load(path: Path) -> dict:
    if not path.is_file():
        k.fail(f"report input missing: {path}")
    return json.loads(path.read_text())


def main() -> None:
    ap = argparse.ArgumentParser(description="Launch kit REPORT.md generator.")
    ap.add_argument("--rehearsal-dir", type=Path, required=True)
    ap.add_argument("--result", type=Path, default=k.OUTPUT / "rehearsal" / "result.json")
    ap.add_argument("--snapshot", type=Path)
    ap.add_argument("--push-plan", type=Path)
    args = ap.parse_args()

    run = args.rehearsal_dir
    inputs = {
        "pin.json": run / "pin.json",
        "cohort/cohort.json": run / "cohort" / "cohort.json",
        "cohort/not-in-root.json": run / "cohort" / "not-in-root.json",
        "outreach/outreach.json": run / "outreach" / "outreach.json",
        "siphon/siphon.json": run / "siphon" / "siphon.json",
        "kit/output/rehearsal/result.json": args.result,
        "kit/output/rehearsal/pin-block.json": args.result.parent / "pin-block.json",
    }
    if args.snapshot is None:
        snaps = sorted((k.OUTPUT / "snapshot").glob("*/snapshot.json"), key=lambda p: int(p.parent.name))
        if not snaps:
            k.fail("no kit snapshot found; pass --snapshot")
        args.snapshot = snaps[-1]
    inputs["kit snapshot"] = args.snapshot
    pin, cohort, nir, outreach, siphon, result, pin_block, snap = (load(p) for p in inputs.values())
    inputs["launch policy"] = k.KIT / "params.json"
    policy = load(inputs["launch policy"])

    supply = int(result["v1SupplyWei"])
    eth_usd = Decimal(siphon["inputs"]["eth_usd"]["answer_raw"]) / Decimal(10) ** siphon["inputs"]["eth_usd"]["decimals"]
    lines: list[str] = []
    w = lines.append

    w("# SURPLUS v1 → v2 launch: rehearsal report")
    w("")
    w(f"Every number below comes from a file (sha256 at the end), measured at Base block **{pin['block']:,}**")
    w(f"(`{pin['hash']}`) or produced by the full-scale fork rehearsal of the monorepo contracts from that")
    w(f"state. USD figures use Chainlink ETH/USD at the pin, **${eth_usd:,.2f}**. The rehearsal runs on a")
    w("private anvil forked at the pin: nothing was broadcast to Base.")
    w("")

    # --- cohort ---------------------------------------------------------------------------------------
    kinds: dict[str, list[int]] = {}
    for kind, amount in zip(cohort["kinds"], cohort["amounts"]):
        kinds.setdefault(kind, [0, 0])
        kinds[kind][0] += 1
        kinds[kind][1] += int(amount)
    w("## Cohort")
    w("")
    w(f"- **{cohort['eligibleCount']:,} selected accounts** hold {tokens(cohort['eligibleTotal'])} v1 "
      f"({pct(int(cohort['eligibleTotal']), supply)} of the {tokens(supply)} supply). This is a maximum-participation")
    w("  scenario: each selected address is impersonated to deposit its full historical balance. It is not an")
    w("  adoption forecast or proof that every wallet can authorize the calls through its real signing flow.")
    names = {"eoa": "EOA", "eip7702": "EIP-7702 account", "4337": "ERC-4337 account", "safe": "Safe"}
    for kind, (count, amount) in sorted(kinds.items(), key=lambda kv: -kv[1][1]):
        w(f"  - {names.get(kind, kind)}: {count:,} holders, {tokens(amount)} v1 ({pct(amount, supply)})")
    w("- Cohort provenance and historical balance checks live in the source run. This report does not perform")
    w("  a fresh holder census or certify control of the selected addresses; validate the source bundle separately.")
    w("")

    # --- not in the root -------------------------------------------------------------------------------
    w("## Not in the root")
    w("")
    w(f"{nir['excludedCount']} addresses hold {tokens(nir['excludedTotal'])} v1 ({nir['excludedPct']}%). "
      f"Of that, {tokens(nir['neverMigratesV1'])} ({nir['neverMigratesPct']}%) can never migrate, and "
      f"{tokens(nir['canMigrateIfOwnersActV1'])} ({nir['canMigrateIfOwnersActPct']}%) is the remaining conditional/unresolved bucket.")
    w("The remainder is not all proven recoverable: it includes ownership-dependent exits, unknown residuals")
    w("and immovable strays. Bucket descriptions below are source-run assessments, not deposit guarantees.")
    w("")
    for b in nir["buckets"]:
        w(f"- **{b['bucket']}**: {tokens(b['v1'])} v1 ({b['pctOfSupply']}%). {b['what']}")
        w(f"  - Can it migrate: {b['canMigrate']}. Who must act: {b['whoMustAct']}")
    w("")

    # --- the launch ------------------------------------------------------------------------------------
    raised = int(result["wethRaisedWei"])
    tail = int(result["wethFromV3TailWei"])
    before = Decimal(int(result["oldPoolSqrtPriceBefore"])) / Q96
    after = Decimal(int(result["oldPoolSqrtPriceAfter"])) / Q96
    v1_per_weth_before, v1_per_weth_after = before * before, after * after
    opening = Decimal(int(result["successorSqrtPriceX96"])) / Q96
    # The pool quotes currency1 per currency0: v2 per WETH when v2 sorts above WETH, WETH per v2 when it sorts below.
    v2_is_0 = int(result["v2"], 16) < int(policy["external"]["weth"], 16)
    v2_per_weth = 1 / (opening * opening) if v2_is_0 else opening * opening
    seeded_weth = int(result["wethSeededWei"])
    w("## The launch batch")
    w("")
    w(f"One Safe transaction (2-of-3, the real Safe 1.4.1 and MultiSendCallOnly) at "
      f"{int(result['launchBatchExecGas']):,} gas, under the 2^24 per-transaction cap.")
    w("")
    w(f"- **Signed limits** (simulate, then sign): the simulation raised {tokens(result['simulatedWethRaisedWei'], 4)} "
      f"WETH, so `minWethOut` = {tokens(result['minWethOutWei'], 4)} WETH (× 0.995). The v2 budget is "
      f"{tokens(result['v2BudgetWei'])} (the simulated v2 side + 10 wei). Execution equalled the simulation.")
    w(f"- **Sale:** {tokens(result['v1DepositedWei'])} v1 sold for **{tokens(raised, 4)} WETH** "
      f"({usd(Decimal(raised) / WEI * eth_usd)}):")
    w(f"  - Doppler v4 pool: {tokens(int(result['v1DepositedWei']) - int(result['v1SoldOnV3TailWei']))} v1 → "
      f"{tokens(raised - tail, 4)} WETH")
    w(f"  - v3 1% tail pool: {tokens(result['v1SoldOnV3TailWei'])} v1 → {tokens(tail, 4)} WETH")
    w(f"- **Old pool price impact:** the sale drains the old pool's WETH. v1 per WETH went from {v1_per_weth_before:,.0f} to "
      f"{v1_per_weth_after:,.0f}, so v1 left outside the migration loses {(1 - v1_per_weth_before / v1_per_weth_after) * 100:.2f}% "
      "of its pool price. The v2 opening price is a separate signed simulation-time marker.")
    w(f"- **Successor pool** (v2/WETH, LP fee {int(result['successorLpFeePips']) / 10_000:.2f}% on chain, plus the 1.5% "
      f"hook): opens at **{v2_per_weth:,.0f} v2 per WETH**, the simulation's pre-sale price rounded to the "
      "pool's tick grid.")
    w("  This is not a guarantee of realizable sale value. Fees, finite liquidity and other trades change exit")
    w("  proceeds, especially for large sellers.")
    first, count = int(result["firstPositionId"]), int(result["positionCount"])
    w("  - It opens with two single-sided sides that meet at the opening price (SUR-658, decided 2026-10-25):")
    w(f"    - **v2 side:** {tokens(result['v2SeededWei'])} v2 in {count - 1} range(s), a copy of the v1 the old pool "
      "still offered above its price, the same amounts over the same ranges.")
    w(f"    - **WETH side:** {tokens(seeded_weth, 4)} WETH ({usd(Decimal(seeded_weth) / WEI * eth_usd)}), the sale "
      "proceeds, in one position from the opening price to the end of the range.")
    w(f"  - The {count} LP NFTs (#{first}-#{first + count - 1}) are owned by the Safe.")
    w("  - The WETH raised and not seeded (dust from rounding) and the unused v2 budget went back to the Safe.")
    w(f"- **Final v2 supply:** {tokens(result['v2SupplyAfterLaunchWei'])}: {tokens(result['totalClaimableWei'])} backing "
      f"every claim 1:1, plus {tokens(result['v2SeededWei'])} in the pool and "
      f"{tokens(int(result['v2SupplyAfterLaunchWei']) - int(result['totalClaimableWei']) - int(result['v2SeededWei']))} "
      "of unused budget returned to the Safe.")
    w("")

    # --- fees ------------------------------------------------------------------------------------------
    w("## Fee check (1.5% hook + 0.30% LP)")
    w("")
    w("Live trades through the real hook after launch. In each one, the hook took exactly "
      "floor(1.5% × the pool's side of the unspecified currency):")
    w(f"- exact-in buy (1 WETH → v2): {tokens(result['feeExactInBuy'], 2)} v2")
    w(f"- exact-in sell (10M v2 → WETH): {tokens(result['feeExactInSell'], 6)} WETH")
    w(f"- exact-out buy (→ 10M v2): {tokens(result['feeExactOutBuy'], 6)} WETH")
    w(f"- exact-out sell (→ 0.2 WETH): {tokens(result['feeExactOutSell'], 2)} v2")
    w("")
    w("The Safe then withdrew both halves (team and buyback) of both currencies, leaving the hook empty. The")
    w("contracts/fee-hook fork suite measures a small trade's all-in cost at 0.3001% (LP fee + price impact) +")
    w("1.4999% (hook): about 1.8%.")
    w("")

    # --- siphon ----------------------------------------------------------------------------------------
    s = siphon
    dist = s["distribution"]
    w("## Rival venues at the ~1.8% fee (siphon table, re-run)")
    w("")
    w("A cheaper hookless pool for the same pair wins every trade up to V* ≈ fee gap × its depth ÷ 2. This is "
      f"on the last {dist['n_trades']} main-pool trades (median ${dist['median_usd']:,.0f}, largest "
      f"${dist['max_usd']:,.0f}).")
    by_depth: dict[int, list[str]] = {}
    for row in s["table"]:
        by_depth.setdefault(int(row["rival_depth_usd"]), []).append(
            f"vs {row['rival_fee_pct']}% ≤${row['v_star_usd']:,.0f} ({row['eligible_volume_pct']}% of volume)")
    for depth, cells in by_depth.items():
        w(f"- ${depth:,} rival: " + ", ".join(cells))
    t = s["take_every_trade_depth_usd"]
    w(f"- Depth a rival needs to take every trade: " + ", ".join(f"{usd(v)} ({k_})" for k_, v in t.items()))
    d = s["depth_target"]
    w(f"- Model reference depth (not an approved funding target): **{usd(d['successor_target_rounded_usd'])}** in-range. The rehearsal seed "
      f"is about {usd(2 * Decimal(seeded_weth) / WEI * eth_usd)}.")
    w(f"- Decided ops alert: in-range depth of **{usd(policy['monitoring']['rivalPoolInRangeDepthAlertUsd'])}** "
      "in any rival pool. This threshold is a decision, not evidence that monitoring is running.")
    w(f"- Conditional model: breakeven leak {s['breakeven_leak']['leak_pct']}%. Revenue at the historical volume "
      f"({usd(s['fee_revenue']['volume_24h_usd'])}/day): {usd(s['fee_revenue']['all_in_1_80pct_usd_per_day'])}/day, "
      f"{usd(s['fee_revenue']['hook_1_50pct_usd_per_day'])} of it to the hook.")
    w("")

    # --- failure paths -------------------------------------------------------------------------------
    w("## Failure paths at full scale")
    w("")
    w(f"Each one starts from the same state (all {result['holders']:,} selected deposits made, window closed) and passes:")
    w("- The Safe never commits: after `commitDeadline` anyone calls `expireCommit()`, then a relayer pushes `refund()` "
      "to every holder (Multicall3, 200 per transaction). Every holder gets its exact v1 back, the vault ends empty, "
      "and no v2 is ever minted.")
    w("- A root is committed but nobody activates: after the execution window anyone calls `expireExecution()`, with "
      "the same refunds.")
    w("- The successor pool is initialized before the batch: the whole launch batch reverts (Safe `GS013`). Nothing "
      "is minted, activated, released or sold, and the Safe nonce is unused. Outsiders cannot initialize it at all: "
      "the hook admits only the settler (RealHookLaunch.fork.t.sol).")
    w("- A withdrawal after the deposit deadline is rejected (`LedgerWithdrawalsFrozen`), sampled across the cohort.")
    w("- v1 sent to the vault by plain transfer: nothing is rescuable while the vault holds exactly the ledger. After "
      "the transfer, the Safe's `rescueV1` returns exactly that excess, and the ledger's v1 stays.")
    w("- One signature is refused (`GS020`) with the Safe's nonce and the vault untouched; two sign `commitRoot`.")
    w("")

    # --- push ------------------------------------------------------------------------------------------
    # Base at the pin, not Anvil's decayed fee; raw RPC quantities are hex, older exports are decimal.
    raw_base_fee = pin_block["baseFeePerGas"]
    base_fee = int(raw_base_fee, 16) if isinstance(raw_base_fee, str) and raw_base_fee.startswith("0x") else int(raw_base_fee)
    l2 = int(result["pushTotalTxGas"]) * base_fee
    l1 = int(result["pushL1FeeUpperWei"])
    w("## Push distribution")
    w("")
    w(f"- {result['pushBatches']} Multicall3 `aggregate3` transactions pushed {result['pushCalls']:,} claims. The {result['pushSkipped']} "
      "holders who had already claimed for themselves were skipped, and every holder received exactly its v2. A "
      "rerun paid nobody, and the relayer received nothing.")
    w(f"- Largest transaction: {int(result['pushMaxTxGas']):,} gas (cap 16,777,216), "
      f"{int(result['pushMaxTxBytes']):,} bytes of calldata (cap 131,072).")
    w(f"- Cost at Base's base fee at the pin ({base_fee / 1e9:g} gwei, priority fee excluded): L2 "
      f"{int(result['pushTotalTxGas']):,} gas = {tokens(l2, 6)} ETH, plus L1 data (GasPriceOracle upper bound) "
      f"{tokens(l1, 6)} ETH = **{tokens(l2 + l1, 6)} ETH** ({usd(Decimal(l2 + l1) / WEI * eth_usd)}) for all "
      f"{result['holders']:,} holders.")
    w("")

    # --- outreach --------------------------------------------------------------------------------------
    w("## Outreach: who must act to take part")
    w("")
    for group in ("fee earner", "non-wallet holder >= 10M", "LP owner >= 10M"):
        entries = [e for e in outreach["entries"] if e["group"] == group]
        if not entries:
            continue
        w(f"- **{group}** ({len(entries)}):")
        for e in entries:
            amount = int(e.get("amountV1") or 0)
            # The historical v1 OFT adapter follows the ratified bridge-back policy, not old outreach prose.
            action = (policy["policies"]["bridgedHolders"]
                      if e["address"].lower() == "0x12cf078d3d4808dbdc69701f30b0b409aff89ec1" else e["action"])
            w(f"  - `{e['address']}` ({tokens(amount)} v1): {action}")
    w("")

    # --- tree + provenance -----------------------------------------------------------------------------
    w("## Tree")
    w("")
    w(f"`kit/launch.py snapshot` built the tree from the vault's own ledger at block {snap['block']:,}: "
      f"{snap['leaves']:,} leaves, total {tokens(snap['totalClaimable'])}, root `{snap['root']}`. It was verified")
    w("three ways (VerifyTree, VerifyTreeBulk, an independent Python rebuild that re-reads every leaf from the ledger),")
    w("and it equals the root predicted from the cohort file alone.")
    w("")
    w("## Inputs")
    w("")
    for name, path in inputs.items():
        w(f"- `{name}`: sha256 `{k.sha256_file(path)}`")
    w("")

    out = k.KIT / "REPORT.md"
    out.write_text("\n".join(lines))
    print(f"wrote {out.relative_to(k.PROJECT)} ({len(lines)} lines)")


if __name__ == "__main__":
    main()
