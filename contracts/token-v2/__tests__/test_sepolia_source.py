"""Generated testnet sources may diverge only at the identifier and chain constant."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/sepolia_source.py"

class SepoliaSourceTest(unittest.TestCase):
    def test_checked_generation_and_manual_drift_rejection(self):
        self.assertTrue(SCRIPT.is_file(), "missing checked Sepolia source generator")
        spec = importlib.util.spec_from_file_location("sepolia_source", SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        source = (ROOT / "src/SurplusTokenV2.sol").read_text()
        generated = module.render(source)
        self.assertEqual(generated, (ROOT / "src/SurplusTokenV2BaseSepolia.sol").read_text())
        module.check(source, generated)
        for changed in (generated + "// edited\n", generated.replace("_disableInitializers();", ""),
                        generated.replace("84532;", "8453;")):
            with self.assertRaisesRegex(ValueError, "parity"):
                module.check(source, changed)
        with self.assertRaisesRegex(ValueError, "source shape"):
            module.render(source.replace("8453;", "1;"))
        run = subprocess.run([sys.executable, str(SCRIPT), "--check"], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)

class SepoliaArtifactTest(unittest.TestCase):
    def test_abi_selectors_and_normalized_layout_match_production(self):
        script = ROOT / "scripts/check_sepolia_artifacts.py"
        self.assertTrue(script.is_file(), "missing compiled Sepolia parity gate")
        result = subprocess.run([sys.executable, str(script)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

if __name__ == "__main__":
    unittest.main()
