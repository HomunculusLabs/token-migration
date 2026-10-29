"""Report language is generated from explicit inputs, not launch-value promises."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

KIT = Path(__file__).resolve().parents[2] / "kit"
sys.path.insert(0, str(KIT))
import kitlib as k
import report


class ReportTests(unittest.TestCase):
    def render_report(self, base_fee=1, **result_overrides):
        # Small synthetic report inputs; never used as chain evidence or a signer packet.
        with tempfile.TemporaryDirectory() as folder:
            project = Path(folder) / "project"
            kit = project / "kit"
            run = project / "run"
            result = {name: 0 for name in (
                "wethRaisedWei", "wethFromV3TailWei", "wethSeededWei", "launchBatchExecGas",
                "simulatedWethRaisedWei", "minWethOutWei", "v2BudgetWei", "v1DepositedWei",
                "v1SoldOnV3TailWei", "v2SeededWei", "firstPositionId", "v2SupplyAfterLaunchWei",
                "totalClaimableWei", "feeExactInBuy", "feeExactInSell", "feeExactOutBuy",
                "feeExactOutSell", "pushTotalTxGas", "pushL1FeeUpperWei", "pushBatches",
                "pushCalls", "pushMaxTxGas", "pushMaxTxBytes", "pushSkipped")}
            result.update(v1SupplyWei=10**18, holders=1, oldPoolSqrtPriceBefore=2**96,
                          oldPoolSqrtPriceAfter=2**97, successorSqrtPriceX96=2**96,
                          successorLpFeePips=3000, pushTotalTxGas=200_000, firstPositionId=7, positionCount=3,
                          v2="0x" + "ff" * 20)
            result.update(result_overrides)
            files = {
                run / "pin.json": {"block": 100, "hash": "0x" + "11" * 32},
                run / "cohort/cohort.json": {"eligibleCount": 1, "eligibleTotal": str(10**18),
                                              "kinds": ["eoa"], "amounts": [str(10**18)]},
                run / "cohort/not-in-root.json": {"excludedCount": 0, "excludedTotal": "0", "excludedPct": "0",
                    "neverMigratesV1": "0", "neverMigratesPct": "0", "canMigrateIfOwnersActV1": "0",
                    "canMigrateIfOwnersActPct": "0", "buckets": []},
                run / "outreach/outreach.json": {"entries": [{"group": "non-wallet holder >= 10M",
                    "address": "0x12cf078d3d4808dbdc69701f30b0b409aff89ec1", "amountV1": "0",
                    "action": "The owner must announce this on the peer chain."}]},
                run / "siphon/siphon.json": {"inputs": {"eth_usd": {"answer_raw": "200000000000", "decimals": 8}},
                    "distribution": {"n_trades": 1, "median_usd": 1, "max_usd": 1}, "table": [],
                    "take_every_trade_depth_usd": {}, "depth_target": {"successor_target_rounded_usd": 200},
                    "ops_alert": {"recommended_trigger_usd": 999}, "breakeven_leak": {"leak_pct": 0},
                    "fee_revenue": {"volume_24h_usd": 1, "all_in_1_80pct_usd_per_day": 0,
                                    "hook_1_50pct_usd_per_day": 0}},
                kit / "output/rehearsal/result.json": result,
                kit / "output/rehearsal/pin-block.json": {"baseFeePerGas": base_fee},
                kit / "output/snapshot/100/snapshot.json": {"block": 100, "leaves": 1,
                    "totalClaimable": str(10**18), "root": "0x" + "22" * 32},
                kit / "params.json": json.loads((KIT / "params.json").read_text()),
            }
            for path, data in files.items():
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(data))
            argv = ["report.py", "--rehearsal-dir", str(run), "--result", str(kit / "output/rehearsal/result.json"),
                    "--snapshot", str(kit / "output/snapshot/100/snapshot.json")]
            with patch.object(k, "KIT", kit), patch.object(k, "PROJECT", project), \
                    patch.object(sys, "argv", argv), contextlib.redirect_stdout(io.StringIO()):
                report.main()
            return (kit / "REPORT.md").read_text()

    def test_opening_price_reads_v2_per_weth_whichever_way_the_pair_sorts(self):
        # The pool quotes currency1 per currency0, so the same 1,000,000 v2 per WETH is 2^96 * 1000 as a sqrt price
        # when v2 sorts above WETH, and 2^96 / 1000 when it sorts below.
        above = self.render_report(v2="0x" + "ff" * 20, successorSqrtPriceX96=2**96 * 1000)
        below = self.render_report(v2="0x" + "01" * 20, successorSqrtPriceX96=2**96 // 1000)
        for text in (above, below):
            self.assertIn("opens at **1,000,000 v2 per WETH**", text)

    def test_report_describes_the_split_seed(self):
        text = self.render_report()
        self.assertIn("two single-sided sides that meet at the opening price", text)
        self.assertIn("v2 in 2 range(s), a copy of the v1 the old pool still offered above its price", text)
        self.assertIn("The 3 LP NFTs (#7-#9) are owned by the Safe.", text)
        self.assertNotIn("full range", text)
        self.assertNotIn("No extra single-sided liquidity", text)

    def test_report_preserves_current_policy_without_guaranteeing_exit_value(self):
        text = self.render_report()
        self.assertNotIn("every migrator keeps its value", text)
        self.assertNotIn("Migrated holders are unaffected", text)
        self.assertIn("not a guarantee", text)
        self.assertIn("maximum-participation", text)
        self.assertIn("$125,000", text)
        self.assertNotIn("a proposal that needs sign-off", text)
        self.assertNotIn("must announce", text)
        self.assertIn("No special outreach", text)

    def test_report_prices_gas_with_rpc_hex_or_decimal_base_fee(self):
        for base_fee in (5_000_000, "5000000", "0x4c4b40"):
            with self.subTest(base_fee=base_fee):
                text = self.render_report(base_fee)
                self.assertIn("base fee at the pin (0.005 gwei", text)
                self.assertIn("200,000 gas = 0.000001 ETH", text)


if __name__ == "__main__":
    unittest.main()
