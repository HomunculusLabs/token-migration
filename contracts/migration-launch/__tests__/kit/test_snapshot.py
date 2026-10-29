"""Signing-boundary regressions; RPC fixtures model the immutable vault ledger."""
import argparse
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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


if __name__ == "__main__":
    unittest.main()
