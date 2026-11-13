"""snapshot-plan regressions: on a real-length deposit window the planned page size must fit the snapshot's own
page cap, and an RPC that cannot serve it must stop the plan before any scan."""
import contextlib
import functools
import io
import json
import sys
import unittest
import urllib.error
from email.message import Message
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "kit"))
import kitlib as k
import snapshot
import snapshot_plan as sp

VAULT, V1 = k.checksum("0x" + "3" * 40), k.checksum("0x" + "c" * 40)
ALICE, BOB, CAROL = ("0x" + f"{i:040x}" for i in (1, 2, 3))
MALLORY = "0x" + "4" * 40
V1_DEPLOY, DEPLOY, DEADLINE_BLOCK = 500_000, 1_000_000, 2_296_000  # 1,296,000 blocks: 30 days of 2 s blocks
DEADLINE = 2_000_000_000
PARAMS = {"chainId": 8453, "vault": {"rateBps": 10000, "proRata": True}, "external": {"v1": V1}}
FREE_TIER = "HTTP 400: Under the Free tier plan, you can make eth_getLogs requests with up to a 10 block range."
PARTIAL_ARCHIVE = "HTTP 403: Archive requests require a personal token."


@functools.cache
def selector(signature: str) -> str:
    return k.selector(signature).hex()  # the plan times batches of eth_calls, so the fake answers hundreds


class Chain:
    """Base as the plan sees it: 2-second blocks, the vault deployed at DEPLOY with DEADLINE_BLOCK the last block
    at its deadline, DepositIssued logs at `deposits` plus `count` more from `who` at each (block, who, count) of
    `flood`, and an RPC serving log pages up to `max_span` blocks."""

    def __init__(self, *, head=2_300_000, finalized=2_299_400, max_span=10_000, client="reth/test",
                 archive=True, deposits=(), flood=(), read_error=None):
        self.head, self.finalized, self.max_span, self.client, self.archive = head, finalized, max_span, client, archive
        self.read_error = read_error  # the JSON-RPC error Http answers every eth_call with
        self.deposits = dict(deposits)
        self.flood = list(flood)
        self.values = {"DEPOSIT_DEADLINE()": DEADLINE, "COMMIT_DEADLINE()": DEADLINE + 7 * 86_400, "phase()": 0,
                       "root()": 0, "credited(address)": 0, "totalSupply()": 10**29}
        self.scanned = []
        self.batches = []

    def number(self, tag) -> int:
        if tag in ("latest", "finalized"):
            return self.head if tag == "latest" else self.finalized
        return int(tag, 16) if isinstance(tag, str) else tag

    def chain_id(self):
        return 8453

    def block(self, tag="latest"):
        n = self.number(tag)
        return {"number": hex(n), "hash": "0x" + "ab" * 32, "timestamp": hex(DEADLINE + (n - DEADLINE_BLOCK) * 2)}

    def eth_call(self, to, data, block="latest"):
        for signature, value in self.values.items():
            if data[2:10] == selector(signature):
                return "0x" + k.word(value).hex()
        raise AssertionError(data)

    def served(self, first, last):
        return (True, "") if last - first + 1 <= self.max_span else (False, FREE_TIER)

    def state(self, block):
        return (True, "") if self.archive or block >= self.head - 10_000 else (False, PARTIAL_ARCHIVE)

    def logs(self, address, first, last):
        """The DepositIssued logs of `address` in blocks [first, last], in block order."""
        events = sorted([*self.deposits.items(), *((n, who) for n, who, count in self.flood for _ in range(count))])
        return [{"address": address, "removed": False, "blockNumber": hex(n),
                 "topics": [snapshot.DEPOSIT_ISSUED, "0x" + k.addr_word(who).hex()], "data": "0x" + "00" * 64}
                for n, who in events if first <= n <= last and address == VAULT]

    def call(self, method, args):
        if method == "web3_clientVersion":
            return self.client
        if method == "eth_getCode":
            address, n = args[0].lower(), self.number(args[1])
            if not self.state(n)[0]:
                k.fail(f"rpc eth_getCode: {PARTIAL_ARCHIVE}")
            deployed = {VAULT.lower(): DEPLOY, V1.lower(): V1_DEPLOY}.get(address)
            return "0x6000" if deployed is not None and n >= deployed else "0x"
        if method == "eth_getLogs":
            first, last = int(args[0]["fromBlock"], 16), int(args[0]["toBlock"], 16)
            if not self.served(first, last)[0]:
                k.fail(f"rpc eth_getLogs: {FREE_TIER}")
            self.scanned.append((first, last))
            return self.logs(args[0]["address"], first, last)
        raise AssertionError((method, args))

    def call_or_none(self, method, args):
        return self.call(method, args)

    def call_or_refusal(self, method, args):
        """kitlib.Rpc.call_or_refusal: a log page wider than the RPC serves is refused with the provider's reason."""
        if method == "eth_getLogs" and not self.served(int(args[0]["fromBlock"], 16), int(args[0]["toBlock"], 16))[0]:
            return False, None, FREE_TIER
        return True, self.call(method, args), ""

    def batch(self, calls):
        self.batches.append(len(calls))
        return [self.eth_call(args[0]["to"], args[0]["data"], args[1]) for _, args in calls]


def run_plan(chain, *argv):
    args = sp.parse_args(["--vault", VAULT, *argv])
    return sp.plan(args, PARAMS, chain, chain.served, chain.state), args


def stopped(test, chain, *argv) -> str:
    """Runs the plan, requires KIT STOP before any log scan, and returns what it said."""
    stderr = io.StringIO()
    with contextlib.redirect_stderr(stderr), test.assertRaises(SystemExit) as stop:
        run_plan(chain, *argv)
    test.assertEqual(stop.exception.code, 2)
    test.assertEqual(chain.scanned, [])
    return stderr.getvalue()


def run_probe(chain):
    with contextlib.redirect_stdout(io.StringIO()) as out:
        problems = sp.probe(sp.parse_args(["--probe", "--window-days", "30"]), PARAMS, chain, chain.served, chain.state)
    return problems, out.getvalue()


class Http:
    """`chain` behind a real kitlib.Rpc: urlopen, answering each JSON-RPC request from the chain. A log page wider than
    the chain serves, or holding more than `cap` logs, and a batch of more than `max_batch` calls are refused the way
    providers refuse: a JSON-RPC error on HTTP 200, or (`http400`) an HTTP 400 whose body holds that error. `pages`
    records every log range asked for."""

    def __init__(self, chain, cap, http400, max_batch=None):
        self.chain, self.cap, self.http400, self.max_batch, self.pages = chain, cap, http400, max_batch, []

    def answer(self, call):
        chain, method, args = self.chain, call["method"], call["params"]
        if method == "eth_getLogs":
            first, last = int(args[0]["fromBlock"], 16), int(args[0]["toBlock"], 16)
            self.pages.append((first, last))
            logs = chain.logs(args[0]["address"], first, last)
            if not chain.served(first, last)[0]:
                return {"jsonrpc": "2.0", "id": call["id"], "error": {"code": -32600, "message": FREE_TIER[10:]}}
            if len(logs) > self.cap:
                return {"jsonrpc": "2.0", "id": call["id"],
                        "error": {"code": -32005, "message": f"query returned more than {self.cap} results"}}
            chain.scanned.append((first, last))
            result = logs
        elif method == "eth_chainId":
            result = hex(chain.chain_id())
        elif method == "eth_getBlockByNumber":
            result = chain.block(args[0])
        elif method == "eth_call" and chain.read_error:
            return {"jsonrpc": "2.0", "id": call["id"], "error": chain.read_error}
        elif method == "eth_call":
            result = chain.eth_call(args[0]["to"], args[0]["data"], args[1])
        else:
            result = chain.call(method, args)
        return {"jsonrpc": "2.0", "id": call["id"], "result": result}

    def __call__(self, request, timeout):
        call = json.loads(request.data)
        if isinstance(call, list) and self.max_batch is not None and len(call) > self.max_batch:
            body = {"jsonrpc": "2.0", "id": None,
                    "error": {"code": -32600, "message": f"batch too large: at most {self.max_batch} calls"}}
        elif isinstance(call, list):
            self.chain.batches.append(len(call))
            body = [self.answer(entry) for entry in call]
        else:
            body = self.answer(call)
        if isinstance(body, dict) and "error" in body and self.http400:
            raise urllib.error.HTTPError("http://127.0.0.1:1", 400, "Bad Request", Message(),
                                         io.BytesIO(json.dumps(body).encode()))
        response = MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps(body).encode()
        return response


def run_main(chain, *argv, cap=10_000, http400=False, max_batch=None):
    """snapshot-plan (--vault VAULT unless `argv` holds --probe) on a real kitlib.Rpc whose urlopen is Http(chain):
    (exit status, stdout, stderr, the Http)."""
    http, out, err = Http(chain, cap, http400, max_batch), io.StringIO(), io.StringIO()
    head = [] if "--probe" in argv else ["--vault", VAULT]
    with patch.object(sys, "argv", ["snapshot_plan.py", *head, "--rpc", "http://127.0.0.1:1", *argv]), \
            patch.object(k, "load_phase_params", return_value=PARAMS), \
            patch.object(k.urllib.request, "urlopen", side_effect=http), patch.object(sp.os, "execv"), \
            contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            sp.main()
            status = 0
        except SystemExit as stop:
            status = stop.code
    return status, out.getvalue(), err.getvalue(), http


class SnapshotPlanTests(unittest.TestCase):
    def test_minimum_page_size_is_exactly_what_the_snapshot_accepts(self):
        need = sp.min_chunk(DEPLOY, DEADLINE_BLOCK)
        self.assertEqual(need, 130)
        chain = Chain()
        with patch.object(chain, "call", return_value=[]):
            snapshot.depositors(chain, VAULT, DEPLOY, DEADLINE_BLOCK, need)
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                snapshot.depositors(chain, VAULT, DEPLOY, DEADLINE_BLOCK, need - 1)
        self.assertEqual(sp.min_chunk(1, 100_000), 10)  # the stock 10-block page covers exactly 100,000 blocks

    def test_free_tier_rpc_stops_before_scanning_and_says_what_it_needs(self):
        said = stopped(self, Chain(max_span=10))
        self.assertIn("at least 130 blocks", said)
        self.assertIn("10 block range", said)

    def test_page_size_prefers_2000_blocks_and_never_exceeds_what_is_served(self):
        for max_span, expected in ((10_000, 2_000), (1_000, 1_000), (500, 500), (200, 200)):
            with self.subTest(max_span=max_span):
                p, _ = run_plan(Chain(max_span=max_span))
                self.assertEqual(p["chunk"], expected)
                self.assertLessEqual(p["pages"], sp.MAX_PAGES)

    def test_planned_command_is_one_the_snapshot_accepts_and_its_scan_finds_the_whole_window(self):
        chain = Chain(deposits={DEPLOY + 5: ALICE, DEPLOY + 650_000: BOB, DEADLINE_BLOCK: CAROL})
        p, args = run_plan(chain)
        with contextlib.redirect_stdout(io.StringIO()) as out:
            command = sp.print_plan(p, args)
        with patch.object(sys, "argv", ["snapshot.py", *command]):
            parsed = snapshot.parse_args()
        self.assertEqual((parsed.block, parsed.from_block, parsed.log_chunk), (2_299_400, DEPLOY, 2_000))
        self.assertEqual(k.checksum(parsed.vault), VAULT)
        self.assertIn("$ python3.14 kit/launch.py snapshot " + " ".join(command), out.getvalue())
        self.assertEqual(p["depositors"], 3)
        self.assertEqual((chain.scanned[0][0], chain.scanned[-1][1]), (DEPLOY, 2_299_400))
        # The reads are timed the way the snapshot makes them: one batch request of READ_BATCH calls.
        self.assertEqual(chain.batches, [snapshot.READ_BATCH] * 5)
        self.assertIn(f"12 ledger reads, {snapshot.READ_BATCH} per batch request", out.getvalue())
        self.assertIn(f"  depositors        3 distinct; the kit's capacity is {snapshot.MAX_DEPOSITORS:,}",
                      out.getvalue())

    def test_waits_while_no_finalized_block_is_past_the_deadline(self):
        chain = Chain(head=DEADLINE_BLOCK + 300, finalized=DEADLINE_BLOCK, deposits={DEPLOY + 5: ALICE})
        with contextlib.redirect_stdout(io.StringIO()) as out, self.assertRaises(SystemExit) as stop:
            run_plan(chain)
        self.assertEqual(stop.exception.code, sp.NOT_READY)
        self.assertIn("not yet", out.getvalue())
        # The daily check during the deposit window: the depositors so far, scanned to the newest finalized block.
        self.assertIn("  depositors        1 distinct;", out.getvalue())
        self.assertEqual((chain.scanned[0][0], chain.scanned[-1][1]), (DEPLOY, DEADLINE_BLOCK))
        # Right after deployment the newest finalized block can predate the vault: nothing to count yet.
        for argv in ((), ("--from-block", str(DEPLOY))):
            chain = Chain(head=DEPLOY + 300, finalized=DEPLOY - 1)
            with contextlib.redirect_stdout(io.StringIO()) as out, self.assertRaises(SystemExit) as stop:
                run_plan(chain, *argv)
            self.assertEqual((stop.exception.code, chain.scanned), (sp.NOT_READY, []))
            self.assertIn("  depositors        0 distinct;", out.getvalue())

    def test_the_daily_check_trips_above_half_the_capacity(self):
        deposits = {DEPLOY + 5: ALICE, DEPLOY + 6: BOB, DEADLINE_BLOCK: CAROL}
        for capacity, code in ((6, sp.NOT_READY), (5, sp.CROWDED)):  # 3 depositors: half of 6 waits, half of 5 trips
            with self.subTest(capacity=capacity):
                chain = Chain(head=DEADLINE_BLOCK + 300, finalized=DEADLINE_BLOCK, deposits=deposits)
                with patch.object(snapshot, "MAX_DEPOSITORS", capacity), \
                        contextlib.redirect_stdout(io.StringIO()) as out, self.assertRaises(SystemExit) as stop:
                    run_plan(chain)
                self.assertEqual(stop.exception.code, code)
                self.assertIn(f"  depositors        3 distinct; the kit's capacity is {capacity}", out.getvalue())
                self.assertEqual("DEPOSITOR CHECK TRIPPED: 3 distinct depositors" in out.getvalue(), code == sp.CROWDED)

    def test_a_tripped_check_after_the_deadline_exits_4_and_never_runs_the_snapshot(self):
        deposits = {DEPLOY + 5: ALICE, DEPLOY + 650_000: BOB, DEADLINE_BLOCK: CAROL}
        for capacity, code in ((6, 0), (5, sp.CROWDED)):
            with self.subTest(capacity=capacity):
                chain = Chain(deposits=deposits)
                argv = ["snapshot_plan.py", "--vault", VAULT, "--rpc", "http://127.0.0.1:1", "--run"]
                with patch.object(sys, "argv", argv), patch.object(snapshot, "MAX_DEPOSITORS", capacity), \
                        patch.object(k, "load_phase_params", return_value=PARAMS), \
                        patch.object(k, "Rpc", return_value=chain), \
                        patch.object(sp, "logs_served", side_effect=lambda url, vault, a, b: chain.served(a, b)), \
                        patch.object(sp, "state_served", side_effect=lambda url, vault, b: chain.state(b)), \
                        patch.object(sp.os, "execv") as execv, contextlib.redirect_stdout(io.StringIO()) as out:
                    try:
                        sp.main()
                        status = 0
                    except SystemExit as stop:
                        status = stop.code
                self.assertEqual(status, code)
                self.assertEqual(execv.called, code == 0)
                self.assertIn("$ python3.14 kit/launch.py snapshot", out.getvalue())  # the command is still printed

    def test_an_explicit_page_size_between_sampled_spans_is_probed_directly(self):
        # widest_page() samples only SPANS: a 150-block provider reports widest=100, which used to
        # falsely reject this window's 130-block minimum even though --log-chunk 130 names a
        # servable size. The explicit chunk must be probed directly and the plan must proceed.
        chain = Chain(max_span=150)
        p, args = run_plan(chain, "--log-chunk", "130")
        self.assertEqual(args.log_chunk, 130)
        self.assertEqual(p["chunk"], 130)
        self.assertEqual(chain.scanned[0][1] - chain.scanned[0][0] + 1, 130)

    def test_launch_day_refuses_a_private_anvil_and_a_rehearsal_accepts_one(self):
        stopped(self, Chain(client="anvil/v1.4.0"))
        p, _ = run_plan(Chain(client="anvil/v1.4.0"), "--rehearsal")
        self.assertEqual(p["chunk"], 2_000)

    def test_stops_once_committed_or_past_the_commit_deadline(self):
        now = DEADLINE + (2_300_000 - DEADLINE_BLOCK) * 2
        for change in ({"root()": 1}, {"phase()": 1}, {"COMMIT_DEADLINE()": now - 1}):
            with self.subTest(change=change):
                chain = Chain()
                chain.values.update(change)
                stopped(self, chain)

    def test_explicit_page_size_must_still_fit_the_page_cap(self):
        stopped(self, Chain(), "--log-chunk", "129")
        p, _ = run_plan(Chain(), "--log-chunk", "500")
        self.assertEqual(p["chunk"], 500)

    def test_a_node_without_deep_state_needs_the_recorded_deploy_block(self):
        self.assertIn("pass --from-block", stopped(self, Chain(archive=False)))
        p, _ = run_plan(Chain(archive=False), "--from-block", str(DEPLOY))
        self.assertEqual((p["start"], p["chunk"]), (DEPLOY, 2_000))

    def test_probe_flags_a_free_tier_rpc_without_scanning(self):
        chain = Chain(max_span=10)
        problems, out = run_probe(chain)
        self.assertTrue(any("the window needs 130" in p for p in problems), problems)
        self.assertEqual(chain.scanned, [])
        self.assertIn("NOT OK", out)

    def test_probe_passes_a_wide_archive_rpc_after_scanning_the_full_window(self):
        problems, out = run_probe(Chain())
        self.assertEqual(problems, [])
        self.assertIn("648 pages of 2,000 blocks", out)
        self.assertIn(f"deploy block, {V1_DEPLOY:,}", out)
        self.assertIn(f"a batch request of {snapshot.READ_BATCH}", out)
        self.assertIn("OK: this RPC can serve", out)

    def test_probe_flags_a_pruned_node(self):
        problems, out = run_probe(Chain(archive=False))
        self.assertTrue(any("archive node" in p for p in problems), problems)
        self.assertIn("pass --from-block on launch day", out)

    def test_refusal_keeps_the_providers_reason_but_not_urls(self):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "error": {"code": -32600, "message":
                           FREE_TIER[10:] + " Upgrade at https://dashboard.example/key-123"}}).encode()
        error = urllib.error.HTTPError("https://rpc.example/v2/secret", 400, "Bad Request", Message(), io.BytesIO(body))
        with patch.object(k.urllib.request, "urlopen", side_effect=error):
            ok, reason = sp.logs_served(k.Rpc("https://rpc.example/v2/secret"), VAULT, 1, 11)
        self.assertFalse(ok)
        self.assertIn("HTTP 400: Under the Free tier plan", reason)
        self.assertNotIn("key-123", reason)
        response = MagicMock()
        response.__enter__.return_value.read.return_value = b'{"jsonrpc":"2.0","id":1,"result":[]}'
        with patch.object(k.urllib.request, "urlopen", return_value=response):
            self.assertEqual(sp.logs_served(k.Rpc("https://rpc.example/v2/secret"), VAULT, 1, 10), (True, ""))
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "error": {"code": -32602, "message": PARTIAL_ARCHIVE[10:]}})
        error = urllib.error.HTTPError("https://rpc.example", 403, "Forbidden", Message(), io.BytesIO(body.encode()))
        with patch.object(k.urllib.request, "urlopen", side_effect=error):
            self.assertEqual(sp.state_served(k.Rpc("https://rpc.example"), VAULT, 1), (False, PARTIAL_ARCHIVE))

    def test_the_width_probes_read_pages_that_end_before_the_scan(self):
        # Before the vault's deploy block its log pages are empty, so only the RPC's range limit can refuse them.
        # A scan that starts too early to leave the widest probe room is probed at the snapshot block instead.
        block = 2_299_400
        for argv, probe, start in (((), (DEPLOY - 10_000, DEPLOY - 1), DEPLOY),
                                   (("--log-chunk", "500"), (DEPLOY - 500, DEPLOY - 1), DEPLOY),
                                   (("--from-block", "10000"), (0, 9_999), 10_000),
                                   (("--from-block", "9999"), (block - 9_999, block), 9_999),
                                   (("--from-block", "2000", "--log-chunk", "2000"), (0, 1_999), 2_000),
                                   (("--from-block", "1999", "--log-chunk", "2000"), (block - 1_999, block), 1_999),
                                   (("--from-block", "0"), (block - 9_999, block), 0)):
            with self.subTest(argv=argv):
                status, out, _, http = run_main(Chain(), *argv)
                self.assertEqual(status, 0, out)
                self.assertEqual(http.pages[0], probe)
                self.assertEqual(http.pages[1][0], start)  # then the scan
        # A probe page cut short at block 0 would pass on an RPC that refuses the width it stands for.
        status, out, _, _ = run_main(Chain(max_span=1_000), "--from-block", "5")
        self.assertEqual(status, 0, out)
        self.assertIn("  page size         1,000 blocks (10,000 pages need at least 230; this RPC serves 1,000-block "
                      "pages)\n", out)

    def test_the_daily_check_reads_a_stuffed_last_page_and_waits(self):
        # Before the deadline, one account put 3 events into the scan's last page, on an RPC that returns at most 2
        # logs in one reply: the width probes never see them, and the scan reads that page in halves.
        finalized = DEADLINE_BLOCK - 1_000
        flood = [(block, MALLORY, 1) for block in range(finalized - 2, finalized + 1)]
        for http400 in (False, True):
            with self.subTest(http400=http400):
                chain = Chain(head=finalized + 300, finalized=finalized, deposits={DEPLOY + 5: ALICE}, flood=flood)
                status, out, err, _ = run_main(chain, cap=2, http400=http400)
                self.assertEqual(status, sp.NOT_READY, err)
                self.assertIn("  depositors        2 distinct;", out)
                self.assertIn("not yet: DEPOSIT_DEADLINE", out)
                self.assertIn("depositor scan: the RPC refused", err)
                self.assertEqual(chain.scanned[-1][1], finalized)

    def test_after_the_deadline_a_stuffed_last_page_still_plans(self):
        flood = [(block, MALLORY, 1) for block in range(2_299_398, 2_299_401)]
        for http400 in (False, True):
            with self.subTest(http400=http400):
                chain = Chain(deposits={DEPLOY + 5: ALICE, DEPLOY + 650_000: BOB}, flood=flood)
                status, out, err, _ = run_main(chain, cap=2, http400=http400)
                self.assertEqual(status, 0, err)
                self.assertRegex(out, r"dry-run scan      650 pages in \w+: 3 depositors")
                self.assertIn(f"$ python3.14 kit/launch.py snapshot --block 2299400 --vault {VAULT} --from-block "
                              f"{DEPLOY} --log-chunk 2000 --rpc <rpc>\n", out)
                self.assertIn("depositor scan: the RPC refused", err)

    def test_the_read_batch_is_timed_and_reaches_the_snapshot_command_only_when_chosen(self):
        for argv, batch in (((), snapshot.READ_BATCH), (("--read-batch", "7"), 7)):
            with self.subTest(argv=argv):
                chain = Chain(deposits={DEPLOY + 5: ALICE, DEPLOY + 650_000: BOB, DEADLINE_BLOCK: CAROL})
                p, args = run_plan(chain, *argv)
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    command = sp.print_plan(p, args)
                self.assertEqual(chain.batches, [batch] * 5)
                self.assertIn(f"12 ledger reads, {batch} per batch request", out.getvalue())
                self.assertEqual(command[8:], ["--read-batch", "7"] if argv else [])  # the default prints as before
                with patch.object(sys, "argv", ["snapshot.py", *command]):
                    self.assertEqual(snapshot.parse_args().read_batch, batch)
        self.assertEqual(sp.parse_args(["--probe", "--read-batch", "7"]).read_batch, 7)
        for argv in (["--vault", VAULT, "--read-batch", "0"], ["--probe", "--read-batch", "0"]):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()) as err, \
                    self.assertRaises(SystemExit):
                sp.parse_args(argv)
            self.assertIn("--read-batch must be at least 1", err.getvalue())

    def test_run_hands_a_chosen_read_batch_to_the_snapshot(self):
        chain = Chain(deposits={DEPLOY + 5: ALICE})
        argv = ["snapshot_plan.py", "--vault", VAULT, "--rpc", "http://127.0.0.1:1", "--run", "--read-batch", "7"]
        with patch.object(sys, "argv", argv), patch.object(k, "load_phase_params", return_value=PARAMS), \
                patch.object(k, "Rpc", return_value=chain), \
                patch.object(sp, "logs_served", side_effect=lambda rpc, vault, a, b: chain.served(a, b)), \
                patch.object(sp, "state_served", side_effect=lambda rpc, vault, b: chain.state(b)), \
                patch.object(sp.os, "execv") as execv, contextlib.redirect_stdout(io.StringIO()):
            sp.main()
        self.assertEqual(execv.call_args.args[1][-4:], ["--read-batch", "7", "--rpc", "http://127.0.0.1:1"])

    def test_a_probe_rpc_that_fails_the_ledger_read_is_one_problem_that_names_the_read_batch(self):
        for http400 in (False, True):
            with self.subTest(http400=http400):
                status, out, err, _ = run_main(Chain(), "--probe", max_batch=50, http400=http400)
                self.assertEqual(status, sp.NOT_SERVED)
                self.assertIn("  archive state     served", out)  # the rest of the probe still reports
                reason = ("HTTP Error 400: Bad Request" if http400 else
                          '{"code": -32600, "message": "batch too large: at most 50 calls"}')
                self.assertIn("NOT OK: a ledger read of 100 eth_calls per request failed (rpc batch of 100: "
                              f"{reason}): try a smaller --read-batch\n", out)
                self.assertNotIn("KIT STOP", err)
        # One call per request cannot be made smaller, so there the advice is left out.
        down = {"code": -32000, "message": "header not found"}
        status, out, _, _ = run_main(Chain(read_error=down), "--probe", "--read-batch", "1")
        self.assertEqual(status, sp.NOT_SERVED)
        self.assertIn("  eth_call          a read of 1 eth_call per request failed: rpc eth_call: ", out)
        self.assertIn("NOT OK: a ledger read of 1 eth_call per request failed (rpc eth_call: "
                      f"{json.dumps(down)})\n", out)
        status, out, _, _ = run_main(Chain(), "--probe", "--read-batch", "50", max_batch=50)
        self.assertEqual(status, 0, out)
        self.assertIn("ms a batch request of 50; the snapshot makes 4 per depositor", out)
        self.assertIn("OK: this RPC can serve the snapshot of a 30-day deposit window", out)


if __name__ == "__main__":
    unittest.main()
