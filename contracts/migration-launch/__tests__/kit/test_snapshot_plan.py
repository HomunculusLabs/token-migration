"""snapshot-plan regressions: on a real-length deposit window the planned page size must fit the snapshot's own
page cap, and an RPC that cannot serve it must stop the plan before any scan."""
import contextlib
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
V1_DEPLOY, DEPLOY, DEADLINE_BLOCK = 500_000, 1_000_000, 2_296_000  # 1,296,000 blocks: 30 days of 2 s blocks
DEADLINE = 2_000_000_000
PARAMS = {"chainId": 8453, "vault": {"rateBps": 10000, "proRata": True}, "external": {"v1": V1}}
FREE_TIER = "HTTP 400: Under the Free tier plan, you can make eth_getLogs requests with up to a 10 block range."
PARTIAL_ARCHIVE = "HTTP 403: Archive requests require a personal token."


class Chain:
    """Base as the plan sees it: 2-second blocks, the vault deployed at DEPLOY with DEADLINE_BLOCK the last block
    at its deadline, DepositIssued logs at `deposits`, and an RPC serving log pages up to `max_span` blocks."""

    def __init__(self, *, head=2_300_000, finalized=2_299_400, max_span=10_000, client="reth/test",
                 archive=True, deposits=()):
        self.head, self.finalized, self.max_span, self.client, self.archive = head, finalized, max_span, client, archive
        self.deposits = dict(deposits)
        self.values = {"DEPOSIT_DEADLINE()": DEADLINE, "COMMIT_DEADLINE()": DEADLINE + 7 * 86_400, "phase()": 0,
                       "root()": 0, "credited(address)": 0, "totalSupply()": 10**29}
        self.scanned = []

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
            if data[2:10] == k.selector(signature).hex():
                return "0x" + k.word(value).hex()
        raise AssertionError(data)

    def served(self, first, last):
        return (True, "") if last - first + 1 <= self.max_span else (False, FREE_TIER)

    def state(self, block):
        return (True, "") if self.archive or block >= self.head - 10_000 else (False, PARTIAL_ARCHIVE)

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
            return [{"address": args[0]["address"], "removed": False, "blockNumber": hex(n),
                     "topics": [snapshot.DEPOSIT_ISSUED, "0x" + k.addr_word(who).hex()], "data": "0x" + "00" * 64}
                    for n, who in self.deposits.items() if first <= n <= last and args[0]["address"] == VAULT]
        raise AssertionError((method, args))

    def call_or_none(self, method, args):
        return self.call(method, args)


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

    def test_waits_while_no_finalized_block_is_past_the_deadline(self):
        chain = Chain(head=DEADLINE_BLOCK + 300, finalized=DEADLINE_BLOCK)
        with contextlib.redirect_stdout(io.StringIO()) as out, self.assertRaises(SystemExit) as stop:
            run_plan(chain)
        self.assertEqual(stop.exception.code, sp.NOT_READY)
        self.assertIn("not yet", out.getvalue())
        self.assertEqual(chain.scanned, [])

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
        self.assertIn("OK: this RPC can serve", out)

    def test_probe_flags_a_pruned_node(self):
        problems, out = run_probe(Chain(archive=False))
        self.assertTrue(any("archive node" in p for p in problems), problems)
        self.assertIn("pass --from-block on launch day", out)

    def test_refusal_keeps_the_providers_reason_but_not_urls(self):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "error": {"code": -32600, "message":
                           FREE_TIER[10:] + " Upgrade at https://dashboard.example/key-123"}}).encode()
        error = urllib.error.HTTPError("https://rpc.example/v2/secret", 400, "Bad Request", Message(), io.BytesIO(body))
        with patch.object(sp.urllib.request, "urlopen", side_effect=error):
            ok, reason = sp.logs_served("https://rpc.example/v2/secret", VAULT, 1, 11)
        self.assertFalse(ok)
        self.assertIn("HTTP 400: Under the Free tier plan", reason)
        self.assertNotIn("key-123", reason)
        response = MagicMock()
        response.__enter__.return_value.read.return_value = b'{"jsonrpc":"2.0","id":1,"result":[]}'
        with patch.object(sp.urllib.request, "urlopen", return_value=response):
            self.assertEqual(sp.logs_served("https://rpc.example/v2/secret", VAULT, 1, 10), (True, ""))
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "error": {"code": -32602, "message": PARTIAL_ARCHIVE[10:]}})
        error = urllib.error.HTTPError("https://rpc.example", 403, "Forbidden", Message(), io.BytesIO(body.encode()))
        with patch.object(sp.urllib.request, "urlopen", side_effect=error):
            self.assertEqual(sp.state_served("https://rpc.example", VAULT, 1), (False, PARTIAL_ARCHIVE))


if __name__ == "__main__":
    unittest.main()
