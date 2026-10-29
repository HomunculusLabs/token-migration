"""A successful Forge exit must never hide a skipped full-scale rehearsal."""
import contextlib
import io
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "kit"))
import rehearsal_gate


class RehearsalGateTests(unittest.TestCase):
    def test_only_seven_passing_tests_without_skips_is_accepted(self):
        rehearsal_gate.verify_output("Ran 1 test suite in 2s: 7 tests passed, 0 failed, 0 skipped (7 total tests)", 0)
        for summary, code in (
            ("Ran 1 test suite in 2s: 0 tests passed, 0 failed, 7 skipped (7 total tests)", 0),
            ("Ran 1 test suite in 2s: 3 tests passed, 4 failed, 0 skipped (7 total tests)", 1),
            ("No tests found in project!", 0),
            ("Ran 1 test suite in 2s: 1 tests passed, 0 failed, 0 skipped (1 total tests)", 0),
            ("Ran 1 test suite in 2s: 7 tests passed, 0 failed, 0 skipped (7 total tests)", 1),
        ):
            with self.subTest(summary=summary, code=code), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit):
                rehearsal_gate.verify_output(summary, code)


if __name__ == "__main__":
    unittest.main()
