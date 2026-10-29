"""Unsigned Sepolia kit contract. Network-backed lifecycle is an explicit local rehearsal."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time
import unittest

PROJECT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT / "kit/testnet/prepare.py"


def module():
    spec = importlib.util.spec_from_file_location("testnet_prepare", SCRIPT)
    assert spec is not None and spec.loader is not None
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def fixture():
    now = int(time.time())
    return {"schema": 1, "mode": "testnet", "chainId": 84532,
            "validUntil": now + 7200, "deployer": "0x" + "11" * 20,
            "governance": {"owners": ["0x" + "22" * 20, "0x" + "33" * 20, "0x" + "44" * 20],
                           "threshold": 2, "saltNonce": 768},
            "token": {"name": "TEST ONLY Surplus V2", "symbol": "TEST-V2", "capWei": "1000000000000000000000000"},
            "vault": {"depositDeadline": now + 1800, "commitDeadline": now + 3600,
                      "executionWindowSeconds": 1800, "claimPeriodSeconds": 0, "rateBps": 10000, "proRata": True}}


class TestnetInputs(unittest.TestCase):
    def test_explicit_params_fail_closed_and_cli_accepts_no_secrets_or_broadcast(self):
        self.assertTrue(SCRIPT.is_file(), "missing isolated unsigned testnet CLI")
        p = module()
        good = fixture()
        p.validate(good)
        cases = [("chainId", 8453), ("mode", "production"), ("deployer", " " + good["deployer"]),
                 ("deployer", "0x123"), ("validUntil", 1), ("privateKey", "never-load-this"),
                 ("deployer", "TBD")]
        for key, value in cases:
            bad = copy.deepcopy(good)
            bad[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                p.validate(bad)
        for threshold in (0, 1, 4, True, "2", "TBD"):
            bad = copy.deepcopy(good)
            bad["governance"]["threshold"] = threshold
            with self.assertRaises(ValueError):
                p.validate(bad)
        bad = copy.deepcopy(good)
        bad["governance"]["owners"][1] = bad["governance"]["owners"][0]
        with self.assertRaises(ValueError):
            p.validate(bad)
        for key, value in (("rateBps", 9999), ("claimPeriodSeconds", 1), ("proRata", False),
                           ("depositDeadline", good["vault"]["commitDeadline"] + 1)):
            bad = copy.deepcopy(good)
            bad["vault"][key] = value
            with self.assertRaises(ValueError):
                p.validate(bad)
        for flag in ("--private-key", "--broadcast", "--execute"):
            result = subprocess.run([sys.executable, str(SCRIPT), "validate", flag, "x"],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
        rpc = p.ReadRpc("https://sepolia.base.org")
        for method in ("eth_sendTransaction", "eth_sendRawTransaction", "anvil_setBalance", "personal_sign"):
            with self.assertRaisesRegex(ValueError, "read-only"):
                rpc.call(method, [])

class TestnetPreflight(unittest.TestCase):
    def test_dependency_hash_and_finalized_chain_identity_fail_closed(self):
        p = module()
        self.assertTrue(hasattr(p, "preflight"), "missing read-only dependency preflight")
        deps = p.dependencies()
        class Rpc:
            wrong_chain = False
            wrong_code = False
            def eth_call(self, to, data, block):
                return self.call("eth_call", [to, data, block])
            def chain_id(self):
                return 8453 if self.wrong_chain else 84532
            def block(self, tag="latest"):
                return {"number": "0x1", "hash": "0x" + "ab" * 32, "timestamp": hex(int(time.time()))}
            def call(self, method, args):
                if method == "web3_clientVersion": return "reth/public"
                if method == "eth_getCode": return "0x6001" if self.wrong_code else "0x6000"
                if method == "eth_call": return "0x" + (p.k.word(32) + p.safe.dyn(b"safe proxy code")).hex()
                raise AssertionError(method)
        rpc = Rpc()
        # Network fault injection uses a tiny dependency fixture; the CLI always loads pinned official hashes.
        tiny = {key: dict(value, runtimeCodeHash="0x" + p.k.keccak(bytes.fromhex("6000")).hex())
                for key, value in deps["contracts"].items()}
        import unittest.mock
        with unittest.mock.patch.object(p, "dependencies", return_value=dict(deps, contracts=tiny)):
            proof = p.preflight(fixture(), rpc)
            self.assertEqual(proof["chainId"], 84532)
            self.assertEqual(proof["block"]["hash"], "0x" + "ab" * 32)
            rpc.wrong_code = True
            with self.assertRaisesRegex(ValueError, "code hash"):
                p.preflight(fixture(), rpc)
            rpc.wrong_code = False
            rpc.wrong_chain = True
            with self.assertRaisesRegex(ValueError, "84532"):
                p.preflight(fixture(), rpc)

class TestnetPlan(unittest.TestCase):
    def test_historical_plan_retains_the_seven_day_approval_bound(self):
        p = module()
        good = fixture()
        pin_time = good["vault"]["depositDeadline"] - 2000
        proof = {"chainId": 84532, "scope": "public-read-only", "paramsHash": p.digest(good),
                 "block": {"number": 47589038, "hash": "0x15080179575aafa17c3f4f1e18e63994c0402f27200f2329a708bce1f1276f94",
                           "timestamp": pin_time}, "finality": "finalized", "dependencies": p.dependencies(),
                 "proxyCreationCode": p.dependencies()["proxyCreationCode"]}
        from unittest.mock import patch
        for extra in (0, 1):
            params = copy.deepcopy(good)
            params["validUntil"] = pin_time + 7 * 86400 + extra
            bound_proof = dict(proof, paramsHash=p.digest(params))
            with patch.object(p.time, "time", return_value=params["validUntil"] + 1):
                if extra:
                    with self.assertRaises(ValueError):
                        plan = p.make_plan(params, bound_proof, for_deployment=False)
                        p.check_plan(plan, params)
                else:
                    plan = p.make_plan(params, bound_proof, for_deployment=False)
                    self.assertEqual(p.check_plan(plan, params), plan)

    def test_deterministic_unsigned_plan_binds_params_sources_and_deployment_inputs(self):
        p = module()
        self.assertTrue(hasattr(p, "make_plan"), "missing deterministic unsigned deployment plan")
        good = fixture()
        proof = {"chainId": 84532, "scope": "public-read-only", "paramsHash": p.digest(good),
                 "block": {"number": 47589038, "hash": "0x15080179575aafa17c3f4f1e18e63994c0402f27200f2329a708bce1f1276f94",
                           "timestamp": good["vault"]["depositDeadline"] - 2000},
                 "finality": "finalized", "dependencies": p.dependencies(),
                 "proxyCreationCode": p.dependencies()["proxyCreationCode"]}
        stale = copy.deepcopy(good)
        stale["vault"]["depositDeadline"] = int(time.time()) - 1
        stale_proof = dict(proof, paramsHash=p.digest(stale))
        with self.assertRaisesRegex(ValueError, "deployment window"):
            p.make_plan(stale, stale_proof)
        plan = p.make_plan(good, proof)
        self.assertEqual(plan, p.make_plan(good, proof))
        self.assertEqual(len(plan["transactions"]), 5)
        self.assertEqual(set(plan["addresses"]), {"safe", "v1", "implementation", "token", "vault"})
        self.assertTrue(all(tx["chainId"] == 84532 and tx["value"] == "0x0" for tx in plan["transactions"]))
        self.assertNotIn("privateKey", json.dumps(plan))
        p.check_plan(plan, good)
        from unittest.mock import patch
        # The deployment approval expires; immutable identity and recovery must not.
        with patch.object(p.time, "time", return_value=good["validUntil"]):
            self.assertEqual(p.check_plan(plan, good), plan)
            with self.assertRaises(ValueError): p.validate(good)
            with self.assertRaises(ValueError): p.make_plan(good, proof)
            bad = copy.deepcopy(plan)
            bad["sourceHash"] = "0" * 64
            with self.assertRaises(ValueError): p.check_plan(bad, good)
        for field in ("paramsHash", "sourceHash", "planHash"):
            bad = copy.deepcopy(plan)
            bad[field] = "0" * 64
            with self.assertRaises(ValueError): p.check_plan(bad, good)
        bad = copy.deepcopy(plan)
        bad["transactions"][0]["data"] += "00"
        with self.assertRaises(ValueError): p.check_plan(bad, good)
        wrong = copy.deepcopy(good)
        wrong["governance"]["saltNonce"] += 1
        with self.assertRaises(ValueError): p.make_plan(wrong, proof)

class TestnetTransitions(unittest.TestCase):
    def test_cancel_and_both_timeouts_have_disjoint_eligibility(self):
        p = module()
        self.assertTrue(hasattr(p, "check_transition"), "missing phase/deadline preconditions")
        state = {"phase": 0, "active": 0, "now": 101, "depositDeadline": 100, "commitDeadline": 200,
                 "committedAt": 0, "executionWindow": 50, "total": 10, "supply": 0, "cap": 100}
        p.check_transition("commit-root", state)
        p.check_transition("cancel", state)
        for name in ("activate", "expire-commit", "expire-execution", "refund"):
            with self.assertRaises(ValueError): p.check_transition(name, state)
        state["now"] = 201
        p.check_transition("expire-commit", state)
        with self.assertRaises(ValueError): p.check_transition("commit-root", state)
        state.update(phase=1, committedAt=180, now=230)
        p.check_transition("activate", state)
        with self.assertRaises(ValueError): p.check_transition("expire-execution", state)
        state["now"] = 231
        p.check_transition("expire-execution", state)
        with self.assertRaises(ValueError): p.check_transition("activate", state)
        state["active"] = 1
        for name in ("activate", "expire-execution", "cancel", "refund"):
            with self.assertRaises(ValueError): p.check_transition(name, state)
        state.update(phase=2, active=0)
        p.check_transition("refund", state)

    def test_packet_identity_and_allocation_tree_reject_tampering(self):
        p = module()
        self.assertTrue(hasattr(p, "build_tree"), "missing frozen-ledger tree generation")
        rows = [("0x" + "11" * 20, 80), ("0x" + "22" * 20, 150), ("0x" + "33" * 20, 20)]
        tree = p.build_tree(rows)
        self.assertEqual(tree["total"], "250")
        self.assertEqual(tree["leafCount"], 3)
        for leaf in tree["leaves"]:
            h = p.k.keccak(p.k.word(leaf["index"]) + bytes.fromhex(leaf["account"][2:]) + p.k.word(int(leaf["amount"])))
            for sibling in leaf["proof"]:
                b = bytes.fromhex(sibling[2:])
                h = p.k.keccak(min(h, b) + max(h, b))
            self.assertEqual("0x" + h.hex(), tree["root"])
        for bad in ([], rows + [rows[0]], [(rows[0][0], 0)]):
            with self.assertRaises(ValueError): p.build_tree(bad)

class TestnetExplorer(unittest.TestCase):
    def test_explorer_emits_real_standard_json_without_submission(self):
        p = module()
        self.assertTrue(hasattr(p, "explorer_inputs"), "missing explorer verification inputs")
        inputs = p.explorer_inputs()
        self.assertEqual(set(inputs), {"v1", "implementation", "token", "vault"})
        for source in inputs.values():
            self.assertEqual(source["language"], "Solidity")
            self.assertEqual(source["settings"]["evmVersion"], "cancun")
            self.assertEqual(source["settings"]["optimizer"]["runs"], 200)
            self.assertTrue(source["sources"])

class TestnetLocalBoundary(unittest.TestCase):
    def test_public_and_dns_named_endpoints_never_reach_rehearsal_rpc(self):
        sys.path.insert(0, str(SCRIPT.parent))
        spec = importlib.util.spec_from_file_location("testnet_rehearse", SCRIPT.parent / "rehearse.py")
        assert spec is not None and spec.loader is not None
        rehearse = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(rehearse)
        from unittest.mock import patch
        with patch.object(rehearse.p, "ReadRpc", side_effect=AssertionError("network reached")):
            for url in ("https://sepolia.base.org", "http://localhost:8545", "http://127.0.0.1.evil:8545",
                        "http://user@127.0.0.1:8545", "http://127.0.0.1:8545?token=x"):
                with self.assertRaises(ValueError): rehearse.guard(url, {}, "https://sepolia.base.org")

class TestnetLiteralTypes(unittest.TestCase):
    def test_json_booleans_are_not_numeric_decisions(self):
        p = module()
        good = fixture()
        bad = copy.deepcopy(good)
        bad["schema"] = True
        with self.assertRaises(ValueError): p.validate(bad)
        bad = copy.deepcopy(good)
        bad["vault"]["claimPeriodSeconds"] = False
        with self.assertRaises(ValueError): p.validate(bad)

class TestnetRotationReceipt(unittest.TestCase):
    def test_official_safe141_execution_hash_is_indexed(self):
        p = module()
        self.assertTrue(hasattr(p, "execution_success"), "missing indexed Safe 1.4.1 receipt predicate")
        safe_address = "0x" + "22" * 20
        tx_hash = "0x2dca65653ccda909990a54859abe9bc3902092e606605b2221edb261201776d0"
        log = {"address": safe_address, "topics": [p.safe.EXECUTION_SUCCESS, tx_hash],
               "data": "0x" + "00" * 32, "removed": False}
        self.assertTrue(p.execution_success(log, safe_address, tx_hash))
        self.assertFalse(p.execution_success(dict(log, removed=True), safe_address, tx_hash))
        self.assertFalse(p.execution_success(log, "0x" + "33" * 20, tx_hash))
        self.assertFalse(p.execution_success(log, safe_address, "0x" + "44" * 32))

class TestnetPlannedConfig(unittest.TestCase):
    def test_planned_config_is_public_disabled_and_not_a_deployment_receipt(self):
        p = module()
        self.assertTrue(hasattr(p, "planned_config"), "missing disabled public planning config")
        # Pure formatting fixture: no claim that these test addresses are deployed.
        plan = {"planHash": "11" * 32, "addresses": {"v1": "0x" + "11" * 20,
                "token": "0x" + "22" * 20, "vault": "0x" + "33" * 20}}
        config = p.planned_config(plan, {"runtimeCodeHashes": {"vault": "0x" + "44" * 32}})
        self.assertEqual(config["raw"]["enabled"], "false")
        self.assertEqual(config["raw"]["mode"], "testnet")
        self.assertEqual(config["raw"]["depositOpen"], "TBD")
        self.assertEqual(config["scope"], "public-plan-not-deployed")

if __name__ == "__main__":
    unittest.main()
