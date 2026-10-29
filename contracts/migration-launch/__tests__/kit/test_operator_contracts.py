"""Exercise the literal operator commands without making any RPC calls."""
import contextlib
import io
import os
from pathlib import Path
import re
import runpy
import shlex
import sys
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[2]
KIT = PROJECT / "kit"
sys.path.insert(0, str(KIT))
import kitlib as k
import launch


class ParsedCommand(Exception):
    pass


def enter_phase(_executable, argv):
    with patch.object(sys, "argv", argv[1:]):
        runpy.run_path(argv[1], run_name="__main__")


class RunbookCommandTests(unittest.TestCase):
    def test_commit_root_command_supplies_an_independent_canonical_rpc(self):
        import safe_txs
        commands = [line for line in (KIT / "RUNBOOK.md").read_text().splitlines()
                    if line.startswith("python3.14 kit/launch.py safe-txs commit-root ")]
        self.assertEqual(len(commands), 1)
        argv = shlex.split(re.sub(r"<[^>]+>", "canonical-placeholder", commands[0]))[3:]
        argv = ["0" if part == "K" else part for part in argv]
        with patch.object(sys, "argv", ["safe_txs.py", *argv]):
            args = safe_txs.parse_args()
        self.assertEqual(args.canonical_rpc, "canonical-placeholder")
        self.assertFalse(args.rehearsal)
        k.require_loopback(args.rpc)

    def test_documented_phase_commands_reach_parameter_loading(self):
        commands = [line.strip() for line in (KIT / "RUNBOOK.md").read_text().splitlines()
                    if line.startswith("python3.14 kit/launch.py ")]
        self.assertGreaterEqual(len(commands), 5)
        for command in commands:
            with self.subTest(command=command):
                text = re.sub(r"<[^>]+>", "placeholder", command)
                argv = [{"K+1": "1", "K": "0", "N": "100", "D": "1", "C": "2000"}.get(part, part)
                        for part in shlex.split(text)[1:]]
                with contextlib.chdir(PROJECT), contextlib.redirect_stderr(io.StringIO()), \
                        contextlib.redirect_stdout(io.StringIO()), patch.object(sys, "argv", argv), \
                        patch.object(os, "execv", side_effect=enter_phase), \
                        patch.object(k, "load_params", side_effect=ParsedCommand), \
                        self.assertRaises(ParsedCommand):
                    launch.main()


if __name__ == "__main__":
    unittest.main()
