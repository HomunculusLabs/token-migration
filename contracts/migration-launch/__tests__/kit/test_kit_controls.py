"""Offline launch-kit integrity controls; all artifacts are private fixtures."""
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
import check
import kitlib as k


class ManifestTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name) / "kit"
        self.directory.mkdir()
        self.manifest: dict = {"schema": "surplus-v2-launch-kit-manifest/1"}
        files = {
            "committed": check.COMMITTED,
            "outputs": check.RECORDED_OUTPUTS + [f"output/snapshot/100/{name}" for name in
                                                 ("snapshot.json", "deposits.csv", "tree.json", "tree.csv")],
            "evidence": ["evidence/verification.txt"],
        }
        for section, names in files.items():
            self.manifest[section] = {}
            for name in names:
                file = self.directory / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text("fixture\n")
                self.manifest[section][name] = k.sha256_file(file)
        binding = patch.object(k, "KIT", self.directory)
        binding.start()
        self.addCleanup(binding.stop)

    def test_complete_inventory_with_matching_hashes_passes(self):
        self.assertEqual(check.check_hashes(self.manifest), [])

    def test_changed_or_missing_artifact_fails(self):
        file = self.directory / "output/deploy/plan.json"
        file.write_text("changed\n")
        self.assertTrue(any("plan.json" in p and "sha256" in p for p in check.check_hashes(self.manifest)))
        file.unlink()
        self.assertTrue(any("plan.json" in p and "missing" in p for p in check.check_hashes(self.manifest)))

    def test_omitting_output_inventory_fails_even_when_committed_files_match(self):
        self.manifest["outputs"] = {}
        problems = check.check_hashes(self.manifest)
        self.assertTrue(any("inventory" in p and "outputs" in p for p in problems), problems)

    def test_omitting_retained_push_artifacts_fails(self):
        for name in ("plans/reviewed/batch-000.calldata", "executions/reviewed/attempt/request.json",
                     "progress.json"):
            with self.subTest(name=name):
                rel = f"output/push-plan/{name}"
                path = self.directory / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("retained distribution evidence\n")
                problems = check.check_hashes(self.manifest)
                self.assertTrue(any(rel in p and "inventory" in p for p in problems), problems)
                self.manifest["outputs"][rel] = k.sha256_file(path)
                self.assertEqual(check.check_hashes(self.manifest), [])

    def test_omitting_evidence_inventory_fails(self):
        self.manifest["evidence"] = {}
        problems = check.check_hashes(self.manifest)
        self.assertTrue(any("evidence" in p and "inventory" in p for p in problems), problems)

    def test_omitting_signed_packet_or_snapshot_files_fails(self):
        for prefix in ("output/safe-txs/", "output/snapshot/"):
            with self.subTest(prefix=prefix):
                manifest = json.loads(json.dumps(self.manifest))
                manifest["outputs"] = {p: digest for p, digest in manifest["outputs"].items()
                                       if not p.startswith(prefix)}
                problems = check.check_hashes(manifest)
                self.assertTrue(any(prefix in p and "inventory" in p for p in problems), problems)

    def test_path_escape_in_manifest_fails_before_reading_it(self):
        outside = self.directory.parent / "outside.txt"
        outside.write_text("not a kit artifact")
        self.manifest["outputs"]["../outside.txt"] = k.sha256_file(outside)
        problems = check.check_hashes(self.manifest)
        self.assertTrue(any("../outside.txt" in p and "path" in p for p in problems), problems)

    def test_incomplete_snapshot_and_invalid_schema_fail(self):
        del self.manifest["outputs"]["output/snapshot/100/tree.csv"]
        self.assertTrue(any("tree.csv" in p and "inventory" in p for p in check.check_hashes(self.manifest)))
        self.manifest["schema"] = "unknown"
        self.assertEqual(check.check_hashes(self.manifest), ["manifest: invalid schema"])


class ParameterModeTests(unittest.TestCase):
    def test_production_does_not_accept_rehearsal_key_material(self):
        with tempfile.TemporaryDirectory() as folder:
            copied = Path(folder) / "production.json"
            copied.write_text(json.dumps({"mode": "production", "rehearsalKeys": {}}))
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                k.load_phase_params(copied)

    def test_modes_are_explicit_and_do_not_fill_open_decisions(self):
        self.assertEqual(k.load_phase_params()["governance"]["owners"],
                         k.load_params()["governance"]["owners"])
        self.assertEqual(k.load_phase_params(rehearsal=True)["mode"], "rehearsal")
        with tempfile.TemporaryDirectory() as folder:
            copied = Path(folder) / "missing-mode.json"
            copied.write_text("{}")
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                k.load_phase_params(copied)
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                k.load_phase_params(copied, rehearsal=True)

    def test_renamed_rehearsal_parameters_are_rejected_for_production(self):
        with tempfile.TemporaryDirectory() as folder:
            copied = Path(folder) / "approved.json"
            copied.write_bytes((KIT / "params.rehearsal.json").read_bytes())
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                k.load_phase_params(copied)


class LoopbackTests(unittest.TestCase):
    def test_userinfo_cannot_turn_a_loopback_prefix_into_a_remote_host(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            k.require_loopback("http://127.0.0.1:8545@review.invalid:8545")

    def test_local_endpoints_pass_and_remote_or_malformed_endpoints_fail(self):
        for url in ("http://127.0.0.1:8545", "http://localhost:18549", "http://[::1]:8545"):
            with self.subTest(url=url):
                k.require_loopback(url)
        for url in ("https://review.invalid:8545", "http://localhost", "http://localhost:99999",
                    "http://localhost:bad", "http://127.0.0.1.example:8545", "http://[broken",
                    "http://localhost:8545#fragment", "http://user@localhost:8545"):
            with self.subTest(url=url), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                k.require_loopback(url)


if __name__ == "__main__":
    unittest.main()
