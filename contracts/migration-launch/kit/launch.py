#!/usr/bin/env python3.14
"""The launch kit's front door: one command per launch phase.

    python3.14 kit/launch.py <phase> [phase options]

Phases, in launch order (each prints what it wrote and stops loudly on any problem or open decision):

    deploy-plan   predicted addresses, init-code hashes, Basescan inputs, fork dry run   (kit/deploy_plan.py)
    snapshot-plan page size for the real deposit window, the RPC's limits, dry-run scan (kit/snapshot_plan.py)
    snapshot      the vault's deposits at a block → deposits.csv → tree → 3-way verify  (kit/snapshot.py)
    safe-txs      commitRoot + the launch contract and its one Safe transaction: calldata,
                  safeTxHash, deployment, simulate-then-sign limits                       (kit/safe_txs.py)
    push-plan     Multicall3 claim batches (< 128 KB, < 2^24 gas), idempotent, cost       (kit/push_plan.py)
    check         manifest hashes, byte-identical regeneration, only §6 decisions TBD     (kit/check.py)

Every phase reads kit/params.json. The rehearsal uses kit/params.rehearsal.json through --rehearsal, which
the phases refuse to mix with a launch run. No phase broadcasts to Base; local simulations use private
forks. Real signing and sending stay with the Safe
signers, the deployer and the relayer (RUNBOOK.md).
"""
import os
import sys
from pathlib import Path

KIT = Path(__file__).resolve().parent
PHASES = {
    "deploy-plan": "deploy_plan.py",
    "snapshot-plan": "snapshot_plan.py",
    "snapshot": "snapshot.py",
    "safe-txs": "safe_txs.py",
    "push-plan": "push_plan.py",
    "check": "check.py",
}


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help") or sys.argv[1] not in PHASES:
        print(__doc__)
        sys.exit(0 if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help") else 2)
    script = KIT / PHASES[sys.argv[1]]
    if not script.is_file():
        print(f"KIT STOP: phase {sys.argv[1]} is not in this kit ({script.name} missing)", file=sys.stderr)
        sys.exit(2)
    os.chdir(KIT.parent)  # every phase runs from contracts/migration-launch
    os.execv(sys.executable, [sys.executable, str(script), *sys.argv[2:]])


if __name__ == "__main__":
    main()
