"""Signing-boundary regressions; RPC fixtures model the immutable vault ledger."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from email.message import Message
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "kit"))
import kitlib as k
import safe_txs
import snapshot

ALICE, BOB, VAULT = ("0x" + f"{i:040x}" for i in (1, 2, 3))
HASH = "0x" + "ab" * 32
PARAMS = {"chainId": 31337, "vault": {"rateBps": 10000, "proRata": True, "depositDeadline": 100}}


def tree_file(directory, amounts=(100, 100)):
    rows = [{"index": i, "account": a, "amount": str(n)}
            for i, (a, n) in enumerate(zip((ALICE, BOB), amounts))]
    hashes = [k.keccak(k.word(r["index"]) + bytes.fromhex(r["account"][2:]) + k.word(int(r["amount"])))
              for r in rows]
    root = hashes[0] if len(hashes) == 1 else k.keccak(b"".join(sorted(hashes)))
    for i, row in enumerate(rows):
        row["proof"] = [] if len(rows) == 1 else ["0x" + hashes[1-i].hex()]
    path = directory / "tree.json"
    k.write_json(path, {"root": "0x" + root.hex(), "total": str(sum(amounts)), "leafCount": len(rows), "leaves": rows})
    return path


def manifest(path, **overrides):
    tree = json.loads(path.read_text())
    result = {"chainId": 31337, "vault": VAULT, "block": 12, "blockHash": HASH, "blockTimestamp": 101,
              "rateBps": 10000, "scannedFromBlock": 1, "root": tree["root"], "totalClaimable": tree["total"],
              "netLedgerV1": "200", "leaves": tree["leafCount"], "sha256": {"tree.json": k.sha256_file(path)},
              "checks": {"python": {"verdict": "OK"}}}
    result.update(overrides)
    k.write_json(path.parent / "snapshot.json", result)
    return result


class LedgerRpc:
    def __init__(self):
        self.reads = []
        self.batches = []
        self.hash = HASH
        self.finalized = 12
        self.values = {"MIGRATION_RATE_BPS()": 10000, "PRO_RATA_ENABLED()": 1, "DEPOSIT_DEADLINE()": 100,
                       "COMMIT_DEADLINE()": 200, "totalDepositedV1()": 200, "totalLedgerWithdrawnV1()": 0,
                       "phase()": 0, "root()": 0, "claimsEverActive()": 0, "totalClaimedAmount()": 0}

    def chain_id(self):
        return 31337

    def block(self, tag="latest"):
        number = self.finalized if tag == "finalized" else 12 if tag == "latest" else int(tag)
        return {"number": hex(number), "hash": self.hash, "timestamp": hex(101), "baseFeePerGas": "0x1"}

    def eth_call(self, to, data, block="latest"):
        self.reads.append((data, block))
        for sig, value in self.values.items():
            if data[2:10] == k.selector(sig).hex():
                return "0x" + k.word(value).hex()
        if data[2:10] == k.selector("credited(address)").hex():
            return "0x" + k.word(100).hex()
        if data[2:10] == k.selector("withdrawn(address)").hex():
            return "0x" + k.word(0).hex()
        raise AssertionError(data)

    def call(self, method, args):
        if method == "web3_clientVersion":
            return "canonical/test"
        if method == "eth_call":
            return self.eth_call(args[0]["to"], args[0]["data"], args[1])
        if method == "eth_getCode":
            return "0x6000"
        raise AssertionError((method, args))

    call_or_none = call

    def call_or_refusal(self, method, args):
        return True, self.call(method, args), ""

    def batch(self, calls):
        self.batches.append(len(calls))
        return [self.call(method, args) for method, args in calls]


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.rpc = LedgerRpc()

    def test_missing_snapshot_refuses_balanced_tree(self):
        path = tree_file(self.directory, (150, 50))
        with self.assertRaises(SystemExit):
            safe_txs.load_tree(path, VAULT)

    def test_balanced_wrong_tree_cannot_reach_signing(self):
        path = tree_file(self.directory, (150, 50))
        manifest(path)
        args = argparse.Namespace(tree=path, rehearsal=True, safe_nonce=0, execute_on_private_fork=False)
        with patch.object(safe_txs, "cast_calldata", side_effect=lambda *a: self.fail("wrong tree reached signing")):
            with self.assertRaises(SystemExit):
                safe_txs.commit_root(args, PARAMS, self.rpc, {"vault": VAULT}, {}, [])

    def assert_signing_stops(self, path, rehearsal=True):
        args = argparse.Namespace(tree=path, rehearsal=rehearsal, safe_nonce=0, execute_on_private_fork=False,
                                  canonical_rpc=None)
        with patch.object(safe_txs, "cast_calldata", side_effect=lambda *a: self.fail("unverified tree reached signing")):
            with self.assertRaises(SystemExit):
                safe_txs.commit_root(args, PARAMS, self.rpc, {"vault": VAULT}, {}, [])

    def test_snapshot_identity_is_checked_not_its_ok_string(self):
        path = tree_file(self.directory)
        for values in ({"chainId": 8453}, {"blockHash": "0x" + "cd" * 32}, {"blockTimestamp": 99},
                       {"rateBps": 9999}, {"root": "0x" + "00" * 32}, {"totalClaimable": "199"},
                       {"netLedgerV1": "199"}, {"leaves": 1}):
            with self.subTest(values=values):
                manifest(path, **values)
                self.assert_signing_stops(path)

    def test_snapshot_before_deadline_is_rejected(self):
        path = tree_file(self.directory)
        manifest(path)
        self.rpc.values["DEPOSIT_DEADLINE()"] = 101
        self.assert_signing_stops(path)

    def test_omitted_leaf_is_rejected_by_independent_ledger_verifier(self):
        path = tree_file(self.directory, (100,))
        with self.assertRaises(SystemExit):
            snapshot.verify_tree_py(path, self.rpc, VAULT, 12, 10000)

    def test_partial_abi_word_is_not_a_ledger_value(self):
        with patch.object(self.rpc, "eth_call", return_value="0x01"):
            with self.assertRaises(SystemExit):
                snapshot.call_uint(self.rpc, VAULT, k.selector("credited(address)"), 12)

    def test_live_signing_requires_canonical_finality_source(self):
        path = tree_file(self.directory)
        manifest(path)
        self.assert_signing_stops(path, rehearsal=False)

    def test_live_ledger_is_read_from_canonical_rpc_not_mutable_fork(self):
        path = tree_file(self.directory)
        manifest(path)
        authority = LedgerRpc()
        original = authority.eth_call
        def canonical_call(to, data, block="latest"):
            if data[2:10] == k.selector("credited(address)").hex():
                return "0x" + k.word(150 if int(data[10:], 16) == int(ALICE, 16) else 50).hex()
            return original(to, data, block)
        with patch.object(authority, "eth_call", side_effect=canonical_call):
            with self.assertRaises(SystemExit):
                snapshot.verify_snapshot(path, self.rpc, VAULT, PARAMS, rehearsal=False, finality_rpc=authority)

    def test_finality_and_canonical_controls(self):
        path = tree_file(self.directory)
        manifest(path)
        good = snapshot.verify_snapshot(path, self.rpc, VAULT, PARAMS, rehearsal=False)
        self.assertEqual(good["finality"], "finalized")
        self.rpc.finalized = 11
        with self.assertRaises(SystemExit):
            snapshot.verify_snapshot(path, self.rpc, VAULT, PARAMS, rehearsal=False)
        self.rpc.finalized = 12
        original = self.rpc.call
        with patch.object(self.rpc, "call", side_effect=lambda m, a: "anvil/test" if m == "web3_clientVersion" else original(m, a)):
            with self.assertRaises(SystemExit):
                snapshot.verify_snapshot(path, self.rpc, VAULT, PARAMS, rehearsal=False)
            self.assertEqual(snapshot.verify_snapshot(path, self.rpc, VAULT, PARAMS, rehearsal=True)["finality"],
                             "private-rehearsal-not-finalized")

    def test_depositor_pagination_rejects_zero_chunk_before_rpc(self):
        with patch.object(self.rpc, "call", side_effect=lambda *a: self.fail("invalid pagination reached RPC")):
            with self.assertRaises(SystemExit):
                snapshot.depositors(self.rpc, VAULT, 1, 12, 0)

    def test_depositor_logs_require_complete_event_abi(self):
        with patch.object(self.rpc, "call", return_value=[{"topics": [snapshot.DEPOSIT_ISSUED, "0x" + k.addr_word(ALICE).hex()]}]):
            with self.assertRaises(SystemExit):
                snapshot.depositors(self.rpc, VAULT, 1, 12, 10)

    def test_signing_binds_loaded_root_to_the_verified_ledger_root(self):
        path = tree_file(self.directory, (150, 50))
        manifest(path)
        original = safe_txs.load_tree
        def replace_after_load(path, vault):
            loaded = original(path, vault)
            tree_file(self.directory)
            manifest(path)
            return loaded
        with patch.object(safe_txs, "load_tree", side_effect=replace_after_load):
            self.assert_signing_stops(path)

    def test_malformed_block_header_is_not_canonical_evidence(self):
        malformed = {"number": "0xc", "timestamp": "0x65", "hash": "0x1"}
        with patch.object(self.rpc, "block", return_value=malformed):
            with self.assertRaises(SystemExit):
                snapshot.check_block(self.rpc, 12, "0x1", rehearsal=True)

    def test_partial_finalized_header_is_not_finality(self):
        path = tree_file(self.directory)
        manifest(path)
        original = self.rpc.block
        with patch.object(self.rpc, "block", side_effect=lambda tag="latest": {"number": "0xc"} if tag == "finalized" else original(tag)):
            with self.assertRaises(SystemExit):
                snapshot.verify_snapshot(path, self.rpc, VAULT, PARAMS, rehearsal=False)


# Twenty-three depositors at block 12: three withdrew everything (no leaf), six withdrew part.
LEDGER = {"0x" + f"{i:040x}": (1000 * i + i, 1000 * i + i if i % 7 == 0 else i if i % 3 == 0 else 0)
          for i in range(10, 33)}
LEDGER_READS = {k.selector("credited(address)").hex(), k.selector("withdrawn(address)").hex()}


def logs_for(accounts, block=5):
    return [{"address": VAULT, "removed": False, "blockNumber": hex(block),
             "topics": [snapshot.DEPOSIT_ISSUED, "0x" + k.addr_word(account).hex()], "data": "0x" + "00" * 64}
            for account in accounts]


class VaultRpc(LedgerRpc):
    """A vault whose `ledger` maps each depositor to (credited, withdrawn) at block 12, with one DepositIssued log
    per depositor at block 5. Counts requests: a plain call is one, a whole batch is one."""

    def __init__(self, ledger):
        super().__init__()
        self.ledger = ledger
        self.requests = 0
        self.values |= {"totalDepositedV1()": sum(c for c, _ in ledger.values()),
                        "totalLedgerWithdrawnV1()": sum(w for _, w in ledger.values())}

    def answer(self, to, data, block):
        for signature, i in (("credited(address)", 0), ("withdrawn(address)", 1)):
            if data[2:10] == k.selector(signature).hex():
                self.reads.append((data, int(block, 16) if isinstance(block, str) else block))
                return "0x" + k.word(self.ledger["0x" + data[-40:]][i]).hex()
        return LedgerRpc.eth_call(self, to, data, block)

    def eth_call(self, to, data, block="latest"):
        self.requests += 1
        return self.answer(to, data, block)

    def call(self, method, args):
        self.requests += 1
        if method == "eth_call":
            return self.answer(args[0]["to"], args[0]["data"], args[1])
        if method == "eth_getLogs":
            return logs_for(self.ledger) if int(args[0]["fromBlock"], 16) <= 5 <= int(args[0]["toBlock"], 16) else []
        return LedgerRpc.call(self, method, args)

    call_or_none = call

    def batch(self, calls):
        self.requests += 1
        self.batches.append(len(calls))
        return [self.answer(args[0]["to"], args[0]["data"], args[1]) for _, args in calls]


def python_tree(out):
    """Stands in for build_and_verify's forge steps: the tree of out/deposits.csv, built in Python."""
    rows = [line.split(",") for line in (out / "deposits.csv").read_text().splitlines()[1:]]
    levels = [[k.keccak(k.word(i) + bytes.fromhex(a[2:]) + k.word(int(n))) for i, (a, n) in enumerate(rows)]]
    while len(levels[-1]) > 1:
        cur = levels[-1]
        levels.append([k.keccak(min(cur[j], cur[j + 1]) + max(cur[j], cur[j + 1])) if j + 1 < len(cur) else cur[j]
                       for j in range(0, len(cur), 2)])

    def proof(i):
        siblings = []
        for level in levels[:-1]:
            if i ^ 1 < len(level):
                siblings.append("0x" + level[i ^ 1].hex())
            i >>= 1
        return siblings

    root = "0x" + levels[-1][0].hex()
    k.write_json(out / "tree.json", {"root": root, "total": str(sum(int(n) for _, n in rows)), "leafCount": len(rows),
                                     "leaves": [{"index": i, "account": a, "amount": n, "proof": proof(i)}
                                                for i, (a, n) in enumerate(rows)]})
    (out / "tree.csv").write_text("index,account,amount\n" + "".join(f"{i},{a},{n}\n" for i, (a, n) in enumerate(rows)))
    return root, {"BuildTree": {"verdict": "OK (Python test double)"}}


def run_snapshot(rpc, output, *flags):
    """snapshot.main() on `rpc` at block 12, writing under `output`: (exit status, stderr)."""
    argv = ["snapshot.py", "--block", "12", "--vault", VAULT, "--from-block", "1", "--rehearsal",
            "--rpc", "http://127.0.0.1:1", *flags]
    stderr = io.StringIO()
    with patch.object(sys, "argv", argv), patch.object(k, "Rpc", return_value=rpc), \
            patch.object(snapshot, "load", return_value=PARAMS), patch.object(k, "OUTPUT", output), \
            patch.object(k, "PROJECT", output), patch.object(snapshot, "build_and_verify", side_effect=python_tree), \
            contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
        try:
            snapshot.main()
        except SystemExit as stop:
            return stop.code, stderr.getvalue()
    return 0, stderr.getvalue()


def http_reply(body):
    """What urlopen returns for an HTTP 200 carrying `body`."""
    response = MagicMock()
    response.__enter__.return_value.read.return_value = json.dumps(body).encode()
    return response


class CappedLogs:
    """urlopen for an RPC holding `logs` that refuses an eth_getLogs reply of more than `cap` logs, or a range wider
    than `span` blocks, the way providers refuse: a JSON-RPC error on HTTP 200, or (`http400`) an HTTP 400 whose body
    holds that error. Records every range asked for and each request's User-Agent."""

    def __init__(self, logs, cap, *, span=None, http400=False):
        self.logs, self.cap, self.span, self.http400 = logs, cap, span, http400
        self.ranges, self.agents = [], []

    def __call__(self, request, timeout):
        call = json.loads(request.data)
        first, last = (int(call["params"][0][key], 16) for key in ("fromBlock", "toBlock"))
        self.ranges.append((first, last))
        self.agents.append(request.get_header("User-agent"))
        found = [log for log in self.logs if first <= int(log["blockNumber"], 16) <= last]
        if self.span is not None and last - first + 1 > self.span:
            error = {"code": -32602, "message": f"block range too wide: at most {self.span} blocks"}
        elif len(found) > self.cap:
            error = {"code": -32005, "message": f"query returned more than {self.cap} results"}
        else:
            return http_reply({"jsonrpc": "2.0", "id": call["id"], "result": found})
        body = {"jsonrpc": "2.0", "id": call["id"], "error": error}
        if self.http400:
            raise k.urllib.error.HTTPError("http://127.0.0.1:1", 400, "Bad Request", Message(),
                                           io.BytesIO(json.dumps(body).encode()))
        return http_reply(body)


def scan(fake, *, end=12, chunk=12):
    """snapshot.depositors over blocks [1, end] through a real kitlib.Rpc whose urlopen is `fake`: (the accounts, or
    the exit status, and stderr)."""
    stderr = io.StringIO()
    with patch.object(k.urllib.request, "urlopen", side_effect=fake), contextlib.redirect_stderr(stderr):
        try:
            return snapshot.depositors(k.Rpc("http://127.0.0.1:1"), VAULT, 1, end, chunk), stderr.getvalue()
        except SystemExit as stop:
            return stop.code, stderr.getvalue()


def testnet_prepare():
    """The testnet kit's prepare.py, home of its read-only RPC, under a module name of its own."""
    spec = importlib.util.spec_from_file_location("testnet_prepare_for_snapshot", k.KIT / "testnet" / "prepare.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DepositFloodTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.output = Path(self.tmp.name)

    def test_one_reply_may_hold_any_number_of_one_accounts_events(self):
        rpc = LedgerRpc()
        with patch.object(rpc, "call", return_value=logs_for([ALICE]) * 1_000_001):
            self.assertEqual(snapshot.depositors(rpc, VAULT, 1, 12, 100), [ALICE])

    def test_one_account_past_the_rpcs_reply_cap_in_one_page_is_read_in_halves(self):
        # 10,001 events from one account in three blocks of one page, on an RPC that returns at most 10,000 logs.
        logs = [log for block, count in ((3, 3_334), (4, 3_334), (5, 3_333)) for log in logs_for([ALICE] * count, block)]
        for http400 in (False, True):
            with self.subTest(http400=http400):
                fake = CappedLogs(logs, 10_000, http400=http400)
                accounts, said = scan(fake)
                self.assertEqual(accounts, [ALICE])
                self.assertEqual(fake.ranges, [(1, 12), (1, 6), (1, 3), (4, 6), (7, 12)])
                self.assertEqual(said.count("depositor scan:"), 1)
                self.assertIn("depositor scan: the RPC refused 2 log requests, and each refused range was read again "
                              "in halves. The first refusal: " + ("HTTP 400: " if http400 else "")
                              + "query returned more than 10000 results\n", said)

    def test_a_stuffed_page_leaves_the_accounts_and_their_order_unchanged(self):
        # 23 accounts at blocks 1, 3, ..., 45 and seven events at block 20 from a newcomer: only the page holding
        # block 20 has more than 8 logs.
        newcomer = "0x" + "5" * 40
        logs = sorted([log for i, account in enumerate(LEDGER) for log in logs_for([account], 1 + 2 * i)]
                      + logs_for([newcomer] * 7, block=20), key=lambda log: int(log["blockNumber"], 16))
        uncapped, said = scan(CappedLogs(logs, len(logs)), end=48)
        self.assertEqual(len(uncapped), len(LEDGER) + 1)
        self.assertNotIn("depositor scan:", said)  # nothing refused, nothing said
        for http400 in (False, True):
            with self.subTest(http400=http400):
                fake = CappedLogs(logs, 8, http400=http400)
                accounts, said = scan(fake, end=48)
                self.assertEqual(accounts, uncapped)  # the same accounts, in the same first-seen order
                self.assertIn("refused 3 log requests", said)
                self.assertEqual(fake.ranges[1:8], [(13, 24), (13, 18), (19, 24), (19, 21), (19, 20), (21, 21),
                                                    (22, 24)])

    def test_more_events_in_one_block_than_one_reply_holds_stops_the_scan_there(self):
        logs = logs_for([ALICE], 3) + logs_for([BOB] * 5, block=7)
        for http400 in (False, True):
            with self.subTest(http400=http400):
                fake = CappedLogs(logs, 4, http400=http400)
                code, said = scan(fake)
                self.assertEqual(code, 2)
                self.assertIn("KIT STOP: the RPC refused the DepositIssued logs of block 7 on its own: "
                              + ("HTTP 400: " if http400 else "") + "query returned more than 4 results. RUNBOOK.md",
                              said)
                self.assertEqual(fake.ranges[-1], (7, 7))

    def test_more_refusals_than_the_bound_stop_the_scan(self):
        # An RPC that refuses every range wider than one block: each 4-block page costs 3 refusals, 9 in all.
        for bound, stops in ((9, False), (8, True)):
            with self.subTest(bound=bound), patch.object(snapshot, "MAX_REFUSED_PAGES", bound):
                fake = CappedLogs(logs_for([ALICE], 6), 10_000, span=1)
                result, said = scan(fake, chunk=4)
                if not stops:
                    self.assertEqual((result, len(fake.ranges)), ([ALICE], 21))
                    self.assertEqual(said.count("depositor scan:"), 1)
                    self.assertIn("refused 9 log requests", said)
                    self.assertIn("The first refusal: block range too wide: at most 1 blocks", said)
                    continue
                self.assertEqual(result, 2)
                self.assertIn("the RPC refused 9 log requests in this scan, more than snapshot.MAX_REFUSED_PAGES (8). "
                              "The latest refusal: block range too wide: at most 1 blocks", said)
                self.assertEqual(len(fake.ranges), 19)  # nothing is sent after the refusal past the bound

    def test_the_summary_gives_the_first_refusal_and_the_bound_stop_the_latest(self):
        # The 12-block page is wider than this RPC serves, and its first half holds more logs than one reply.
        logs = logs_for([ALICE] * 3, 2) + logs_for([BOB] * 3, 5)
        accounts, said = scan(CappedLogs(logs, 4, span=6))
        self.assertEqual(accounts, [ALICE, BOB])
        self.assertIn("the RPC refused 2 log requests, and each refused range was read again in halves. The first "
                      "refusal: block range too wide: at most 6 blocks\n", said)
        with patch.object(snapshot, "MAX_REFUSED_PAGES", 1):
            code, said = scan(CappedLogs(logs, 4, span=6))
        self.assertEqual(code, 2)
        self.assertIn("more than snapshot.MAX_REFUSED_PAGES (1). The latest refusal: query returned more than 4 "
                      "results\n", said)

    def test_only_the_rpcs_own_refusal_is_read_in_halves(self):
        # A request that fails any other way says nothing about the page: the scan stops on it, at the first request.
        def http(status, title, body):
            return k.urllib.error.HTTPError("http://127.0.0.1:1", status, title, Message(), io.BytesIO(body))

        def page(raw):
            response = MagicMock()
            response.__enter__.return_value.read.return_value = raw
            return response
        denied = json.dumps({"jsonrpc": "2.0", "id": 1, "error": {"code": -32000, "message": "invalid API key"}})
        unreadable = http(502, "Bad Gateway", b"")
        unreadable.read = MagicMock(side_effect=OSError("connection reset"))
        for answer, reason in ((TimeoutError("timed out"), "timed out"),
                               (http(401, "Unauthorized", denied.encode()), "HTTP 401: invalid API key"),
                               (http(403, "Forbidden", denied.encode()), "HTTP 403: invalid API key"),
                               (http(502, "Bad Gateway", b"<html>502 Bad Gateway</html>"),
                                "HTTP 502: <html>502 Bad Gateway</html>"),
                               (unreadable, "HTTP 502: Bad Gateway"),
                               (page(b"<html>busy</html>"), "<html>busy</html>"),
                               (page(b""), "an empty reply")):
            with self.subTest(reason=reason):
                sent = []

                def urlopen(request, timeout):
                    sent.append(request)
                    if isinstance(answer, Exception):
                        raise answer
                    return answer
                code, said = scan(urlopen)
                self.assertEqual((code, len(sent)), (2, 1))
                self.assertEqual(said, f"KIT STOP: rpc eth_getLogs: {reason}\n")
        # The same error in the body of a 400 or a 500 is the RPC's own refusal, and so is one beside a result.
        for answer in (http(400, "Bad Request", denied.encode()), http(500, "Internal Server Error", denied.encode()),
                       http_reply({"jsonrpc": "2.0", "id": 1, "result": [], "error": json.loads(denied)["error"]})):
            with self.subTest(answer=answer), patch.object(k.urllib.request, "urlopen", side_effect=[answer]):
                served, result, reason = k.Rpc("http://127.0.0.1:1").call_or_refusal("eth_getLogs", [{}])
                self.assertEqual((served, result, reason.removeprefix(f"HTTP {getattr(answer, 'code', 0)}: ")),
                                 (False, None, "invalid API key"))

    def test_a_rate_limited_log_request_is_sent_again_and_is_not_a_refusal(self):
        limited = {"jsonrpc": "2.0", "id": 1, "error": {"code": 429, "message": "compute units per second"}}

        def too_many():
            return k.urllib.error.HTTPError("http://127.0.0.1:1", 429, "Too Many Requests", Message(),
                                            io.BytesIO(json.dumps(limited).encode()))
        plain = k.urllib.error.HTTPError("http://127.0.0.1:1", 429, "Too Many Requests", Message(), io.BytesIO(b"slow"))
        fake, answers = CappedLogs(logs_for([ALICE], 3), 10_000), [plain, http_reply(limited)]

        def urlopen(request, timeout):
            if not answers:
                return fake(request, timeout)
            answer = answers.pop(0)
            if isinstance(answer, Exception):
                raise answer
            return answer
        with patch.object(k.time, "sleep") as slept:
            accounts, said = scan(urlopen)
        self.assertEqual((accounts, said, fake.ranges), ([ALICE], "", [(1, 12)]))  # served on the third try
        self.assertEqual([wait.args for wait in slept.call_args_list], [(1,), (2,)])
        sent = []

        def always(request, timeout):
            sent.append(request)
            raise too_many()
        with patch.object(k.time, "sleep") as slept:
            code, said = scan(always)
        self.assertEqual((code, len(sent)), (2, 1 + len(k.RATE_LIMIT_WAITS)))
        self.assertEqual([wait.args[0] for wait in slept.call_args_list], list(k.RATE_LIMIT_WAITS))
        self.assertEqual(said, "KIT STOP: rpc eth_getLogs: still rate-limited after 6 more tries over 63 s: HTTP 429: "
                               "compute units per second\n")

    def test_the_testnet_read_only_rpc_keeps_its_filter_through_try_call(self):
        prepare = testnet_prepare()
        logs = logs_for([ALICE], 3) + logs_for([BOB] * 3, block=8) + logs_for([BOB] * 2, block=9)
        rpc, fake = prepare.ReadRpc("http://127.0.0.1:1"), CappedLogs(logs, 4)
        with patch.object(k.urllib.request, "urlopen", side_effect=fake), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(snapshot.depositors(rpc, VAULT, 1, 12, 12), [ALICE, BOB])  # halved through the filter
            self.assertEqual(rpc.try_call("eth_getLogs", [{"fromBlock": "0x1", "toBlock": "0xc"}]),
                             (False, None, "query returned more than 4 results"))
            with self.assertRaisesRegex(ValueError, "read-only RPC: method forbidden"):
                rpc.try_call("eth_sendTransaction", [{}])
        self.assertEqual(set(fake.agents), {"surplus-testnet-preparation/1"})  # every request went through its filter
        self.assertEqual(len(fake.ranges), 8)
        rpc = prepare.ReadRpc("http://127.0.0.1:1")
        with patch.object(k.urllib.request, "urlopen", side_effect=CappedLogs(logs, 4, http400=True)), \
                self.assertRaisesRegex(ValueError, "RPC transport: HTTP Error 400"):
            snapshot.depositors(rpc, VAULT, 1, 12, 12)  # there only a JSON-RPC error is a refusal

    def test_distinct_depositors_past_the_capacity_stop_the_scan(self):
        accounts = list(LEDGER)[:5]
        for count, stops in ((4, False), (5, True)):
            with self.subTest(count=count):
                rpc, stderr = LedgerRpc(), io.StringIO()
                pages = iter([logs_for(accounts[:2]), logs_for(accounts[2:count], block=9)])
                with patch.object(snapshot, "MAX_DEPOSITORS", 4), contextlib.redirect_stderr(stderr), \
                        patch.object(rpc, "call", side_effect=lambda *a: next(pages)):
                    if not stops:
                        self.assertEqual(snapshot.depositors(rpc, VAULT, 1, 12, 6), accounts[:count])
                        continue
                    with self.assertRaises(SystemExit) as stop:
                        snapshot.depositors(rpc, VAULT, 1, 12, 6)
                self.assertEqual(stop.exception.code, 2)
                self.assertIn("more than 4 distinct depositors by block 9", stderr.getvalue())
                self.assertIn("snapshot.MAX_DEPOSITORS", stderr.getvalue())

    def test_the_snapshot_stops_past_the_capacity_before_reading_the_ledger(self):
        rpc = VaultRpc(LEDGER)
        with patch.object(snapshot, "MAX_DEPOSITORS", len(LEDGER) - 1):
            code, said = run_snapshot(rpc, self.output)
        self.assertEqual(code, 2)
        self.assertIn(f"more than {len(LEDGER) - 1} distinct depositors", said)
        self.assertEqual([read for read in rpc.reads if read[0][2:10] in LEDGER_READS], [])
        self.assertFalse((self.output / "snapshot").exists())

    def test_the_kits_capacity_fits_buildtrees_duplicate_table(self):
        source = (k.CONTRACTS / "migration-tools/script/BuildTree.s.sol").read_text()
        (bits,) = re.findall(r"_TABLE_SIZE = 1 << (\d+);", source)
        self.assertGreaterEqual(1 << int(bits), 4 * snapshot.MAX_DEPOSITORS,
                                "the table must stay at most a quarter full")

    def test_the_tree_steps_run_with_the_kits_own_limits(self):
        tools, out, limits = self.output / "tools", self.output / "snapshot", []
        out.mkdir()
        (out / "deposits.csv").write_text("account,amount\n")

        def forge(argv, cwd, env=None, timeout=None, on_timeout=""):
            limits.append(env)
            self.assertEqual((timeout, on_timeout), (590, snapshot.TREE_TOO_SLOW))
            if "BuildTree" in argv:
                k.write_json(tools / "output" / "tree.json", {"root": "0x" + "ab" * 32})
                (tools / "output" / "tree.csv").write_text("index,account,amount\n")
            return 'emit Log(message: "OK: verified")'
        with patch.object(snapshot, "TOOLS", tools), patch.object(k, "run_tool", side_effect=forge):
            tools.mkdir()
            snapshot.build_and_verify(out)
        self.assertEqual(limits, [snapshot.TREE_LIMITS] * 3)
        self.assertGreater(int(snapshot.TREE_LIMITS["FOUNDRY_MEMORY_LIMIT"]), 128 << 20)
        with patch.dict(os.environ, {"FOUNDRY_MEMORY_LIMIT": "1", "FOUNDRY_GAS_LIMIT": "1"}):
            env = k._tool_env(snapshot.TREE_LIMITS)
        self.assertEqual({key: env[key] for key in snapshot.TREE_LIMITS}, snapshot.TREE_LIMITS)

    def test_a_tree_step_past_its_time_limit_stops_and_says_what_to_do(self):
        tools, out = self.output / "tools", self.output / "snapshot"
        tools.mkdir()
        out.mkdir()
        (out / "deposits.csv").write_text("account,amount\n")
        stderr = io.StringIO()
        with patch.object(snapshot, "TOOLS", tools), contextlib.redirect_stderr(stderr), \
                patch.object(k.subprocess, "run", side_effect=subprocess.TimeoutExpired("forge", 590)) as run, \
                self.assertRaises(SystemExit) as stop:
            snapshot.build_and_verify(out)
        self.assertEqual((stop.exception.code, run.call_args.kwargs["timeout"]), (2, 590))
        self.assertIn("KIT STOP: forge script script/BuildTree.s.sol did not finish within its 590 s limit. This "
                      "machine is too slow for a tree this size: run the snapshot on a faster machine. The result is "
                      "the same on any machine", stderr.getvalue())
        stderr = io.StringIO()
        with patch.object(k.subprocess, "run", side_effect=subprocess.TimeoutExpired("forge", 5)), \
                contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
            k.run_tool(["forge", "script", "script/DeployPlan.s.sol", "--fork-url", "https://rpc.example/v2/key-123"],
                       k.PROJECT, timeout=5)
        self.assertIn("KIT STOP: forge script script/DeployPlan.s.sol did not finish within its 5 s limit\n",
                      stderr.getvalue())  # the tool, its script and the limit, and none of its other arguments
        self.assertNotIn("key-123", stderr.getvalue())


class BatchedReadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.output = Path(self.tmp.name)

    def test_a_batched_snapshot_is_byte_identical_to_one_call_per_request(self):
        files, requests, reads = {}, {}, {}
        for batch in ("1", "7", str(snapshot.READ_BATCH)):
            rpc = VaultRpc(LEDGER)
            code, said = run_snapshot(rpc, self.output / batch, "--read-batch", batch)
            self.assertEqual(code, 0, said)
            folder = self.output / batch / "snapshot" / "12"
            files[batch] = {name: (folder / name).read_bytes()
                            for name in ("deposits.csv", "tree.json", "tree.csv", "snapshot.json")}
            requests[batch] = rpc.requests
            reads[batch] = [read for read in rpc.reads if read[0][2:10] in LEDGER_READS]
        self.assertEqual(json.loads(files["1"]["snapshot.json"])["leaves"], 20)
        for batch in ("7", str(snapshot.READ_BATCH)):
            self.assertEqual(files[batch], files["1"])
            self.assertEqual(reads[batch], reads["1"])  # the same reads, in the same order
        self.assertLess(requests["7"], requests["1"])
        self.assertLess(requests[str(snapshot.READ_BATCH)], requests["7"])

    def test_the_verifier_reads_in_batches_from_the_same_rpc_as_before(self):
        path = tree_file(self.output)
        manifest(path)
        rpc, authority = LedgerRpc(), LedgerRpc()
        live = snapshot.verify_snapshot(path, rpc, VAULT, PARAMS, rehearsal=False, finality_rpc=authority)
        self.assertEqual((rpc.batches, authority.batches), ([], [4]))  # the canonical RPC, as before
        fork = LedgerRpc()
        snapshot.verify_snapshot(path, fork, VAULT, PARAMS, rehearsal=True)
        self.assertEqual(fork.batches, [4])
        rpc, authority = LedgerRpc(), LedgerRpc()
        self.assertEqual(snapshot.verify_snapshot(path, rpc, VAULT, PARAMS, rehearsal=False, finality_rpc=authority,
                                                  batch=1), live)
        self.assertEqual(authority.batches, [])

    def test_a_batch_reply_with_a_missing_or_failed_entry_stops_the_phase(self):
        def reply(body):
            response = MagicMock()
            response.__enter__.return_value.read.return_value = json.dumps(body).encode()
            return response

        def ok(i, value):
            return {"jsonrpc": "2.0", "id": i, "result": value}
        call = ("eth_call", [{"to": VAULT, "data": "0x"}, "0xc"])
        sent, rpc = [], k.Rpc("http://127.0.0.1:1")
        with patch.object(k.urllib.request, "urlopen",
                          side_effect=lambda request, timeout: sent.append(json.loads(request.data))
                          or reply([ok(3, "c"), ok(1, "a"), ok(2, "b")])):
            self.assertEqual(rpc.batch([call] * 3), ["a", "b", "c"])  # answers in any order come back in call order
        self.assertEqual([(r["id"], r["method"], r["params"]) for r in sent[0]], [(i, *call) for i in (1, 2, 3)])
        failed = {"jsonrpc": "2.0", "id": 6, "error": {"code": 3, "message": "execution reverted"}}
        for body in ([ok(4, "a"), ok(5, "b")], [ok(4, "a"), ok(5, "b"), failed], [ok(4, "a"), ok(4, "a"), ok(5, "b")],
                     [ok(4, "a"), ok(5, "b"), ok(7, "c")], [ok(4, "a"), ok(5, "b"), {"jsonrpc": "2.0", "id": 6}],
                     {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "batch too large"}},
                     [ok(4, "a"), ok(5, "b"), ok(6, "c"), ok(6, "c")], [ok(4, "a"), ok(5, "b"), failed | ok(6, "c")]):
            with self.subTest(body=body):
                rpc = k.Rpc("http://127.0.0.1:1")
                rpc._id = 3
                with patch.object(k.urllib.request, "urlopen", return_value=reply(body)), \
                        contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    rpc.batch([call] * 3)
        rpc = LedgerRpc()
        with patch.object(rpc, "batch", return_value=["0x" + k.word(1).hex()]), \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            snapshot.read_ledger(rpc, VAULT, [ALICE, BOB], 12, snapshot.READ_BATCH)

    def test_a_rate_limited_batch_is_sent_again_and_so_is_a_single_call(self):
        def reply(body):
            response = MagicMock()
            response.__enter__.return_value.read.return_value = json.dumps(body).encode()
            return response

        def ok(i, value):
            return {"jsonrpc": "2.0", "id": i, "result": value}

        def refused():
            return k.urllib.error.HTTPError("http://127.0.0.1:1", 429, "Too Many Requests", None, None)

        def limited(i, code=429):
            return {"jsonrpc": "2.0", "id": i, "error": {"code": code, "message": "compute units per second"}}
        call = ("eth_call", [{"to": VAULT, "data": "0x"}, "0xc"])
        sent, rpc = [], k.Rpc("http://127.0.0.1:1")
        answers = [refused(), reply([ok(1, "a"), limited(2)]), reply([limited(1, -32005), ok(2, "b")]),
                   reply([ok(2, "b"), ok(1, "a")])]

        def post(request, timeout):
            sent.append(request.data)
            answer = answers.pop(0)
            if isinstance(answer, Exception):
                raise answer
            return answer
        with patch.object(k.urllib.request, "urlopen", side_effect=post), patch.object(k.time, "sleep") as slept:
            self.assertEqual(rpc.batch([call] * 2), ["a", "b"])  # refused whole, then in part twice, then served
        self.assertEqual([wait.args for wait in slept.call_args_list], [(1,), (2,), (4,)])
        self.assertEqual(sent, [sent[0]] * 4)  # the same batch each time
        stderr = io.StringIO()
        with patch.object(k.urllib.request, "urlopen", return_value=reply([ok(3, "a"), limited(4)])), \
                patch.object(k.time, "sleep") as slept, contextlib.redirect_stderr(stderr), \
                self.assertRaises(SystemExit):
            rpc.batch([call] * 2)
        self.assertEqual([wait.args[0] for wait in slept.call_args_list], list(k.RATE_LIMIT_WAITS))
        self.assertIn("still rate-limited", stderr.getvalue())
        self.assertIn("--read-batch", stderr.getvalue())
        reverted = {"jsonrpc": "2.0", "id": 6, "error": {"code": 3, "message": "execution reverted"}}
        with patch.object(k.urllib.request, "urlopen", return_value=reply([ok(5, "a"), reverted])), \
                patch.object(k.time, "sleep") as slept, contextlib.redirect_stderr(io.StringIO()), \
                self.assertRaises(SystemExit):
            rpc.batch([call] * 2)  # any other failed entry stops at once
        slept.assert_not_called()
        # The single call sent right after a batch meets the same limit.
        sent, answers = [], [refused(), refused(), reply(ok(7, "c"))]
        with patch.object(k.urllib.request, "urlopen", side_effect=post), patch.object(k.time, "sleep") as slept:
            self.assertEqual(rpc.call(*call), "c")
        self.assertEqual([wait.args for wait in slept.call_args_list], [(1,), (2,)])
        self.assertEqual(sent, [sent[0]] * 3)  # the same request each time
        stderr = io.StringIO()
        with patch.object(k.urllib.request, "urlopen", side_effect=refused()) as urlopen, \
                patch.object(k.time, "sleep") as slept, contextlib.redirect_stderr(stderr), \
                self.assertRaises(SystemExit):
            rpc.call(*call)
        self.assertEqual(urlopen.call_count, 1 + len(k.RATE_LIMIT_WAITS))
        self.assertEqual([wait.args[0] for wait in slept.call_args_list], list(k.RATE_LIMIT_WAITS))
        self.assertEqual(stderr.getvalue(), "KIT STOP: rpc eth_call: still rate-limited after 6 more tries over 63 s\n")

    def test_an_rpc_that_filters_requests_keeps_its_filter(self):
        class ReadOnly(k.Rpc):
            seen = []

            def _request(self, method, params):
                if method != "eth_call":
                    raise ValueError("read-only RPC: method forbidden")
                self.seen.append(params)
                return {"jsonrpc": "2.0", "id": self._id, "result": "0x" + k.word(len(self.seen)).hex()}
        rpc = ReadOnly("http://127.0.0.1:1")
        with patch.object(k.urllib.request, "urlopen", side_effect=AssertionError("posted around the filter")):
            self.assertEqual(snapshot.read_uints(rpc, VAULT, [b"\x01", b"\x02"], 12, snapshot.READ_BATCH), [1, 2])
            with self.assertRaisesRegex(ValueError, "read-only"):
                rpc.batch([("eth_sendTransaction", [{}])])


if __name__ == "__main__":
    unittest.main()
