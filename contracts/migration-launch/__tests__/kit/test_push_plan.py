"""Mixed claim paths, pinned reconciliation and durable batch history."""
import argparse
import copy
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from test_snapshot import ALICE, BOB, VAULT, HASH, PARAMS, LedgerRpc, tree_file, manifest, k
import push_plan

MC, ORACLE = ("0x" + f"{i:040x}" for i in (4, 5))
CLAIM_PAID = "0x" + k.keccak(b"ClaimPaid(uint256,address,uint256)").hex()
PRO_RATA = "0x" + k.keccak(b"ProRataClaimed(address,uint256)").hex()


def payout(account, index=None, amount=100, block=15):
    topics = [PRO_RATA, "0x" + k.addr_word(account).hex()] if index is None else [
        CLAIM_PAID, "0x" + k.word(index).hex(), "0x" + k.addr_word(account).hex()]
    return {"address": VAULT, "topics": topics, "data": "0x" + k.word(amount).hex(), "blockNumber": hex(block),
            "blockHash": HASH, "transactionHash": "0x" + f"{block:064x}", "logIndex": "0x0", "removed": False}


class PayoutRpc(LedgerRpc):
    def __init__(self, tree):
        super().__init__()
        self.head = 20
        self.events = []
        self.current = {"phase()": 1, "claimsActive()": 1, "claimsExpired()": 0, "claimsEverActive()": 1,
                        "claimWindowEnd()": 1000, "totalClaimable()": 200, "totalClaimedAmount()": 0,
                        "root()": int(tree["root"], 16)}
        self.log_queries = []
        self.sent = []
        self.send_events = []
        self.receipt_status = "0x1"
        self.receipt = None
        self.crash_on_receipt = False

    def block(self, tag="latest"):
        return super().block(self.head if tag == "latest" else tag)

    def eth_call(self, to, data, block="latest"):
        number = self.head if block == "latest" else int(block, 16) if isinstance(block, str) else block
        if to.lower() == MC.lower():
            n = int(data[74:138], 16)
            flags = {int(log["topics"][1], 16) for log in self.events if log["topics"][0] == CLAIM_PAID}
            indices = []
            raw = bytes.fromhex(data[2:])
            start = 4 + 64
            for i in range(n):
                elem = start + int.from_bytes(raw[start+32*i:start+32*(i+1)], "big")
                ptr = elem + int.from_bytes(raw[elem+64:elem+96], "big")
                call = raw[ptr+32:ptr+32+36]
                indices.append(int.from_bytes(call[4:], "big"))
            return "0x" + (k.word(32) + k.word(n) + b"".join(k.word(32*n+128*i) for i in range(n)) +
                           b"".join(k.word(1)+k.word(64)+k.word(32)+k.word(int(i in flags)) for i in indices)).hex()
        if to.lower() == ORACLE.lower():
            return "0x" + k.word(0).hex()
        if number > 12:
            for sig, value in self.current.items():
                if data[2:10] == k.selector(sig).hex():
                    self.reads.append((data, block))
                    return "0x" + k.word(value).hex()
        return super().eth_call(to, data, block)

    def call(self, method, args):
        if method == "eth_getLogs":
            self.log_queries.append(args[0])
            lo, hi = int(args[0]["fromBlock"], 16), int(args[0]["toBlock"], 16)
            return [e for e in self.events if lo <= int(e["blockNumber"], 16) <= hi]
        if method.startswith("anvil_"):
            return True
        if method == "eth_sendTransaction":
            self.sent.append(args[0])
            self.head += 1
            tx_hash = "0x" + f"{self.head:064x}"
            logs = [e | {"blockNumber": hex(self.head), "transactionHash": tx_hash, "logIndex": hex(i)}
                    for i, e in enumerate(self.send_events)]
            self.events.extend(logs)
            self.current["totalClaimedAmount()"] = sum(int(e["data"], 16) for e in self.events)
            self.receipt = {"status": self.receipt_status, "transactionHash": tx_hash, "logs": logs,
                            "blockNumber": hex(self.head), "blockHash": HASH, "gasUsed": "0x186a0"}
            return tx_hash
        if method == "eth_getTransactionReceipt":
            if self.crash_on_receipt:
                raise RuntimeError("injected process crash after broadcast")
            return self.receipt
        if method == "eth_estimateGas":
            return "0x186a0"
        if method == "web3_clientVersion":
            return "anvil/test"
        return super().call(method, args)

    call_or_none = call


class PushTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.path = tree_file(self.directory)
        manifest(self.path)
        self.tree = json.loads(self.path.read_text())
        self.rpc = PayoutRpc(self.tree)
        self.deployment = self.directory / "deployment.json"
        k.write_json(self.deployment, {"vault": VAULT})
        self.params = copy.deepcopy(PARAMS) | {"operators": {"relayer": ALICE},
                       "external": {"multicall3": MC, "gasPriceOracle": ORACLE}}
        self.args = argparse.Namespace(tree=str(self.path), deployment=str(self.deployment), rehearsal=True,
                                       rpc="http://127.0.0.1:18667", on_private_anvil=True, log_chunk=1000)
        self.out = self.directory / "push"
        p = patch.object(push_plan, "OUT", self.out)
        p.start()
        self.addCleanup(p.stop)

    def test_planning_requires_really_active_claims(self):
        for change in ({"claimsActive()": 0}, {"phase()": 2}, {"claimsExpired()": 1}, {"claimWindowEnd()": 100}):
            with self.subTest(change=change):
                original = dict(self.rpc.current)
                self.rpc.current.update(change)
                with self.assertRaises(SystemExit):
                    push_plan.plan(self.args, self.params, self.rpc)
                self.rpc.current = original
        self.assertFalse(self.out.exists())

    def test_formula_claim_and_merkle_claim_both_count_as_paid(self):
        self.rpc.events = [payout(ALICE)]
        self.rpc.current["totalClaimedAmount()"] = 100
        result = push_plan.plan(self.args, self.params, self.rpc)
        self.assertEqual((result["alreadyClaimed"], result["toPush"]), (1, 1))
        self.rpc.events.append(payout(BOB, 1, block=16))
        self.rpc.current["totalClaimedAmount()"] = 200
        result = push_plan.plan(self.args, self.params, self.rpc)
        self.assertEqual((result["alreadyClaimed"], result["toPush"]), (2, 0))
        self.assertEqual(result["totalClaimedAmount"], "200")
        self.assertEqual(result["status"], "complete")
        self.assertTrue(all(int(q["fromBlock"], 16) >= 13 for q in self.rpc.log_queries))
        self.assertFalse(any(block == "latest" for _, block in self.rpc.reads))

    def test_missing_payout_logs_fail_closed_against_total_claimed(self):
        self.rpc.current["totalClaimedAmount()"] = 100
        with self.assertRaises(SystemExit):
            push_plan.plan(self.args, self.params, self.rpc)
        self.assertFalse(self.out.exists())

    def test_malformed_or_wrong_entitlement_events_fail_closed(self):
        good = payout(ALICE)
        for events in ([good | {"data": "0x01"}], [payout(ALICE, amount=99)],
                       [good | {"removed": True}], [good | {"blockHash": "0x" + "ef"*32}],
                       [payout(ALICE, index=999)], [payout(VAULT)], [good, good]):
            with self.subTest(events=events):
                self.rpc.events = events
                self.rpc.current["totalClaimedAmount()"] = 100
                with self.assertRaises(SystemExit):
                    push_plan.plan(self.args, self.params, self.rpc)

    def test_partial_bitmap_response_cannot_silently_omit_holders(self):
        with patch.object(self.rpc, "eth_call", return_value="0x" + (k.word(32)+k.word(0)).hex()):
            with self.assertRaises(SystemExit):
                push_plan.claimed_flags(self.rpc, MC, VAULT, 2)

    def test_replan_preserves_initial_nonempty_batches(self):
        first = push_plan.plan(self.args, self.params, self.rpc)
        original = self.out / first["batches"][0]["file"]
        data = original.read_bytes()
        self.rpc.events = [payout(ALICE), payout(BOB, 1, block=16)]
        self.rpc.current["totalClaimedAmount()"] = 200
        completed = push_plan.plan(self.args, self.params, self.rpc)
        self.assertTrue(original.is_file(), "completion replan deleted the original batch")
        self.assertEqual(original.read_bytes(), data)
        self.assertNotEqual(first["planDirectory"], completed["planDirectory"])
        self.assertEqual(json.loads((self.out / first["planDirectory"] / "plan.json").read_text()), first)
        self.assertEqual(json.loads((self.out / "plan.json").read_text()), completed)
        self.assertEqual(push_plan.plan(self.args, self.params, self.rpc), completed)

    def test_success_receipt_with_unpaid_inner_calls_is_not_delivery(self):
        result = push_plan.plan(self.args, self.params, self.rpc)
        with self.assertRaises(SystemExit):
            push_plan.execute_first(self.args, self.rpc, result, 1)
        progress = json.loads((self.out / "progress.json").read_text())
        self.assertEqual(progress["alreadyClaimed"], 0)
        self.assertEqual(progress["toPush"], 2)
        self.assertEqual(progress["batches"][-1]["actualClaims"], 0)

    def test_partial_payout_reports_only_actual_claims(self):
        result = push_plan.plan(self.args, self.params, self.rpc)
        self.rpc.send_events = [payout(ALICE, 0)]
        with self.assertRaises(SystemExit):
            push_plan.execute_first(self.args, self.rpc, result, 1)
        progress = json.loads((self.out / "progress.json").read_text())
        self.assertEqual((progress["alreadyClaimed"], progress["toPush"]), (1, 1))
        self.assertEqual(progress["batches"][-1]["actualClaims"], 1)

    def test_raced_self_claims_are_not_resent_or_counted_as_batch_payouts(self):
        result = push_plan.plan(self.args, self.params, self.rpc)
        self.rpc.events = [payout(ALICE), payout(BOB, 1, block=16)]
        self.rpc.current["totalClaimedAmount()"] = 200
        push_plan.execute_first(self.args, self.rpc, result, 1)
        self.assertEqual(len(self.rpc.sent), 0)
        progress = json.loads((self.out / "progress.json").read_text())
        self.assertEqual((progress["alreadyClaimed"], progress["toPush"]), (2, 0))
        self.assertEqual(progress["batches"][-1]["actualClaims"], 0)

    def test_crash_after_submission_recovers_counts_without_resending(self):
        result = push_plan.plan(self.args, self.params, self.rpc)
        self.rpc.send_events = [payout(ALICE, 0), payout(BOB, 1)]
        self.rpc.crash_on_receipt = True
        with self.assertRaisesRegex(RuntimeError, "injected process crash"):
            push_plan.execute_first(self.args, self.rpc, result, 1)
        self.rpc.crash_on_receipt = False
        push_plan.execute_first(self.args, self.rpc, result, 1)
        self.assertEqual(len(self.rpc.sent), 1)
        progress = json.loads((self.out / "progress.json").read_text())
        self.assertEqual((progress["alreadyClaimed"], progress["toPush"]), (2, 0))
        self.assertTrue(any(b["actualClaims"] == 2 for b in progress["batches"]))

    def test_cli_resumes_saved_plan_after_crash(self):
        result = push_plan.plan(self.args, self.params, self.rpc)
        self.rpc.send_events = [payout(ALICE, 0), payout(BOB, 1)]
        self.rpc.crash_on_receipt = True
        with self.assertRaises(RuntimeError):
            push_plan.execute_first(self.args, self.rpc, result, 1)
        self.rpc.crash_on_receipt = False
        saved = self.out / result["planDirectory"] / "plan.json"
        argv = ["push_plan.py", "--tree", str(self.path), "--deployment", str(self.deployment),
                "--rpc", self.args.rpc, "--rehearsal", "--on-private-anvil", "--execute-first", "1",
                "--resume-plan", str(saved)]
        with patch.object(push_plan.sys, "argv", argv), patch.object(k, "Rpc", return_value=self.rpc), \
                patch.object(k, "load_phase_params", return_value=self.params), patch.object(push_plan, "_print"):
            try:
                push_plan.main()
            except SystemExit:
                self.fail("CLI cannot resume an immutable plan")
        self.assertEqual(len(self.rpc.sent), 1)
        progress = json.loads((self.out / "progress.json").read_text())
        self.assertTrue(any(b["actualClaims"] == 2 for b in progress["batches"]))

    def test_race_between_read_and_send_reports_zero_new_payouts(self):
        result = push_plan.plan(self.args, self.params, self.rpc)
        original = self.rpc.call
        def race(method, args):
            if method == "eth_sendTransaction":
                self.rpc.events = [payout(ALICE), payout(BOB, 1, block=16)]
                self.rpc.current["totalClaimedAmount()"] = 200
            return original(method, args)
        with patch.object(self.rpc, "call", side_effect=race):
            progress = push_plan.execute_first(self.args, self.rpc, result, 1)
        self.assertEqual((progress["alreadyClaimed"], progress["toPush"]), (2, 0))
        self.assertEqual(progress["batches"][-1]["actualClaims"], 0)
        self.assertEqual(progress["batches"][-1]["racedClaims"], 2)

    def test_crash_before_hash_is_saved_preserves_unknown_attribution(self):
        result = push_plan.plan(self.args, self.params, self.rpc)
        self.rpc.send_events = [payout(ALICE, 0), payout(BOB, 1)]
        original = push_plan.write_once
        def crash(path, text):
            if path.name == "submitted.json":
                raise RuntimeError("crash before persisting tx hash")
            return original(path, text)
        with patch.object(push_plan, "write_once", side_effect=crash):
            with self.assertRaises(RuntimeError):
                push_plan.execute_first(self.args, self.rpc, result, 1)
        progress = push_plan.execute_first(self.args, self.rpc, result, 1)
        self.assertEqual(len(self.rpc.sent), 1)
        self.assertEqual((progress["alreadyClaimed"], progress["toPush"]), (2, 0))
        unknown = next(b for b in progress["batches"] if b["submissionUnknown"])
        self.assertIsNone(unknown["actualClaims"])
        self.assertIsNone(unknown["racedClaims"], "cannot attribute an ambiguous send to racers either")


if __name__ == "__main__":
    unittest.main()
