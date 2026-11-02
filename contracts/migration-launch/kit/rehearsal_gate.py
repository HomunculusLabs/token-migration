#!/usr/bin/env python3.14
"""Run the full-scale local-fork suite with an explicit harness budget and no skipped tests. Its launch sells on the
v3 tail what the kit would sign on the same state: the gate quotes the split as launch-batch does and passes it to
the suite as SURPLUS_TAIL_IN."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kitlib as k
import safe_txs


def verify_output(output: str, exit_code: int) -> None:
    summaries = re.findall(r"Ran \d+ test suites? in [^\n]*: (\d+) tests passed, (\d+) failed, (\d+) skipped", output)
    if exit_code != 0 or summaries != [("7", "0", "0")]:
        k.fail("full-scale rehearsal requires exactly 7 passing tests, zero failures and zero skips")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc", default=os.environ.get("SURPLUS_REHEARSAL_RPC"))
    parser.add_argument("--tree", default=os.environ.get("SURPLUS_TREE"))
    args = parser.parse_args()
    if not args.rpc or not args.tree:
        k.fail("set SURPLUS_REHEARSAL_RPC and SURPLUS_TREE, or supply --rpc and --tree")
    k.require_loopback(args.rpc)
    tree = Path(args.tree).resolve()
    for path in (tree, tree.parent / "snapshot.json", k.OUTPUT / "deploy/deployment.json",
                 k.OUTPUT / "cohort/cohort.json", k.OUTPUT / "cohort/expected-root.json"):
        if not path.is_file():
            k.fail(f"rehearsal input missing: {path}")
    snapshot = json.loads((tree.parent / "snapshot.json").read_text())
    rpc = k.Rpc(args.rpc)
    if rpc.chain_id() != 8453 or "anvil" not in (rpc.call_or_none("web3_clientVersion", []) or "").lower():
        k.fail("full-scale rehearsal requires a private Base Anvil fork")
    head = rpc.block()
    if int(head["number"], 16) != snapshot["block"] or head["hash"].lower() != snapshot["blockHash"].lower():
        k.fail("fork is not at the snapshot's recorded pre-commit block and hash; restore the rehearsal state")
    params = k.load_phase_params(rehearsal=True)
    k.need(params, "successorPool", "sale")
    k.run_tool(["forge", "build", "--deny", "warnings"], k.PROJECT, timeout=590)  # the sale quoter's artifact
    d = json.loads((k.OUTPUT / "deploy/deployment.json").read_text())
    v1_in = (safe_txs.uint(rpc, d["vault"], "totalDepositedV1()")
             - safe_txs.uint(rpc, d["vault"], "totalLedgerWithdrawnV1()"))
    p, _, split = safe_txs.settle_params(params, rpc, d, v1_in)
    print(f"sale split: {p['tailIn']} of the {v1_in} v1 on the v3 tail raises the most WETH ({split['raised']})")
    env = dict(os.environ, SURPLUS_TREE=str(tree), SURPLUS_TAIL_IN=str(p["tailIn"]))
    env["PATH"] = f"{Path.home() / '.foundry/bin'}:{env.get('PATH', '')}"
    (k.OUTPUT / "rehearsal").mkdir(parents=True, exist_ok=True)  # the suite writes result.json there
    result = subprocess.run([
        "forge", "test", "--match-contract", "^FullScaleLaunchRehearsal$",
        "--match-path", "test/fork/rehearsal/*", "--gas-limit", "100000000000",
        "--fork-url", args.rpc, "-vv",
    ], cwd=k.PROJECT, env=env, capture_output=True, text=True)
    output = k.scrub(result.stdout + result.stderr)
    print(output, end="" if output.endswith("\n") else "\n")
    verify_output(output, result.returncode)
    print("FULL-SCALE REHEARSAL OK: 7 passed, 0 failed, 0 skipped")


if __name__ == "__main__":
    main()
