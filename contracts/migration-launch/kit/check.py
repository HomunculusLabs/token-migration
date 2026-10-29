#!/usr/bin/env python3.14
"""Launch kit, phase "check": proves the kit is complete and honest.

    python3.14 kit/check.py                  # verify against kit/manifest.json
    python3.14 kit/check.py --regen --rpc R [--snapshot-rpc P]
                                             # also regenerate the deterministic outputs and require byte identity:
                                             # the deploy plan on R (the pinned fork), the snapshots on P (the fork
                                             # holding the deposits; default R)
    python3.14 kit/check.py --write          # rewrite kit/manifest.json from the current files (after review)

1. Every committed kit artifact listed in manifest.json exists and matches its sha256.
2. Every recorded large output (kit/output/…, gitignored) still matches its recorded sha256.
3. The only "TBD" values left in params.json are exactly the spec §6 open decisions, no more and no fewer.
   Nothing launch-critical can hide as a TBD, and no decision can be silently filled.
4. With --regen, the deterministic phases run again from the recorded inputs (the rehearsal params on the
   given fork), and their outputs must be byte-identical to the recorded ones.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kitlib as k  # noqa: E402

MANIFEST = k.KIT / "manifest.json"

# The spec §6 decisions still open, as the params keys that carry them. params.json must hold exactly these TBDs.
SPEC_6 = {
    "governance.owners": "§6.1 Safe signers (SUR-662)",
    "governance.threshold": "§6.1 Safe threshold (SUR-662)",
    "token.name": "§6.2 v2 name",
    "token.symbol": "§6.2 v2 symbol",
    "token.capWei": "§6.2 v2 supply cap",
    "vault.depositOpen": "§6.3 deposit open",
    "vault.depositDeadline": "§6.3 deposit deadline",
    "vault.commitDeadline": "§6.3 pre-commit timeout",
    "hook.feeRecipient": "§6.4 hook fee recipient",
    "operators.deployer": "§6.7 deployer EOA",
    "operators.relayer": "§6.7 relayer EOA",
}

# §6 decisions Bill has made: params.json (and the rehearsal params) must carry exactly these values.
DECIDED = {
    "vault.claimPeriodSeconds": (0, "§6.5 P5: claims never expire (Bill, 2026-09-29)"),
    "vault.executionWindowSeconds": (2_419_200, "§6.3: the launch must execute within 28 days of the commit "
                                                "(Bill, 2026-10-25)"),
    "seed.openTick": ("pre-sale-tick-rounded", "SUR-658: open at v1's pre-sale tick, on the grid (Bill, 2026-10-25)"),
    "seed.v2Side": ("old-pool-ladder-copy", "SUR-658: v2 copies the old pool's v1 ladder (Bill, 2026-10-25)"),
    "seed.wethSide": ("full-range", "SUR-658: one WETH-only position, open tick to range end (Bill, 2026-10-25)"),
    "seed.mergeBps": (100, "SUR-658: old-pool segments within 1% of liquidity merge (Bill, 2026-10-25)"),
}

# Small reviewed kit files, including this checker; their hashes live in the separate manifest.
COMMITTED = [
    "params.json", "params.rehearsal.json", "kitlib.py", "launch.py", "snapshot.py", "deploy_plan.py", "check.py",
    "safe_txs.py", "seed.py", "push_plan.py", "rehearse.py", "rehearsal_gate.py", "report.py", "snapshot_plan.py",
    "README.md", "RUNBOOK.md", "HOLDERS.md", "REPORT.md", "SIGNER-CHECKLIST.md",
]

# Each Safe transaction's outputs (kit/safe_txs.py). The launch is a DELEGATECALL, which the Transaction Builder cannot
# make, so instead of a Builder import it has the launch contract's deployment.
SAFE_TX_OUTPUTS = {"commitRoot": ("json", "calldata.txt", "safe-tx.json", "safeTxHash.txt"),
                   "launch-batch": ("deploy.json", "calldata.txt", "safe-tx.json", "safeTxHash.txt")}

# The large generated files the manifest pins (kit/output/ is gitignored). Everything a reviewer needs to
# reproduce REPORT.md and the launch transactions; scratch copies and logs are left out.
RECORDED_OUTPUTS = [
    "output/deploy/plan.json", "output/deploy/resolved.json", "output/deploy/deployment.json",
    "output/deploy/basescan.json", "output/deploy/summary.json",
    "output/cohort/cohort.json", "output/cohort/expected-root.json",
    "output/rehearsal/result.json", "output/rehearsal/pin-block.json",
    "output/push-plan/plan.json", "output/safe-txs/simulation.json",
] + [f"output/safe-txs/{name}.{suffix}" for name, suffixes in SAFE_TX_OUTPUTS.items() for suffix in suffixes]


def sha(path: Path) -> str:
    return k.sha256_file(path)


def recorded_outputs() -> list[Path]:
    """RECORDED_OUTPUTS, plus every snapshot's four files and every safe-txs / push-plan output."""
    paths = [k.KIT / rel for rel in RECORDED_OUTPUTS]
    for pattern in ("output/snapshot/*/*", "output/safe-txs/**/*", "output/push-plan/**/*"):
        paths += [p for p in k.KIT.glob(pattern) if p.is_file()]
    missing = [str(p.relative_to(k.KIT)) for p in paths if not p.is_file()]
    if missing:
        k.fail(f"cannot write the manifest: missing outputs {missing}")
    return sorted(set(paths))


def build_manifest() -> dict:
    committed = {}
    for name in COMMITTED:
        path = k.KIT / name
        if path.is_file():
            committed[name] = sha(path)
    evidence = {str(p.relative_to(k.KIT)): sha(p) for p in sorted((k.KIT / "evidence").rglob("*")) if p.is_file()}
    outputs = {str(p.relative_to(k.KIT)): sha(p) for p in recorded_outputs()}
    return {
        "schema": "surplus-v2-launch-kit-manifest/1",
        "note": "sha256 of every kit artifact. `python3.14 kit/check.py` verifies it; --write rewrites it.",
        "committed": committed,
        "evidence": evidence,
        "outputs": outputs,
        "openDecisions": SPEC_6,
        "decided": {key: {"value": value, "why": why} for key, (value, why) in DECIDED.items()},
    }


def check_tbds() -> list[str]:
    params = k.load_params(k.KIT / "params.json")
    found = set(k.tbd_paths(params))
    want = set(SPEC_6)
    problems = []
    rehearsal_params = k.load_params(k.KIT / "params.rehearsal.json")
    for key, (value, why) in DECIDED.items():
        for name, doc in (("params.json", params), ("params.rehearsal.json", rehearsal_params)):
            if k.get(doc, key) != value:
                problems.append(f"{name}: {key} must be {value!r} ({why})")
    for extra in sorted(found - want):
        problems.append(f"params.json: {extra} is TBD but is not a spec §6 decision")
    for missing in sorted(want - found):
        problems.append(f"params.json: {missing} ({SPEC_6[missing]}) is no longer TBD; update SPEC_6 if §6 was decided")
    rehearsal = k.load_params(k.KIT / "params.rehearsal.json")
    if k.tbd_paths(rehearsal):
        problems.append(f"params.rehearsal.json still has TBDs: {k.tbd_paths(rehearsal)}")
    return problems


def check_hashes(manifest: dict) -> list[str]:
    if not isinstance(manifest, dict) or manifest.get("schema") != "surplus-v2-launch-kit-manifest/1":
        return ["manifest: invalid schema"]
    problems = []
    inventories = {}
    for section in ("committed", "evidence", "outputs"):
        entries = manifest.get(section)
        if not isinstance(entries, dict) or not entries:
            problems.append(f"{section}: inventory must be a nonempty object")
            entries = {}
        inventories[section] = entries
    for section, required in (("committed", COMMITTED), ("outputs", RECORDED_OUTPUTS)):
        for rel in sorted(set(required) - set(inventories[section])):
            problems.append(f"{section}: inventory is missing {rel}")
    snapshot_dirs = {Path(rel).parent for rel in inventories["outputs"]
                     if isinstance(rel, str) and rel.startswith("output/snapshot/") and len(Path(rel).parts) == 4}
    if not snapshot_dirs:
        problems.append("outputs: inventory is missing output/snapshot/<block>/")
    for directory in snapshot_dirs:
        for name in ("snapshot.json", "deposits.csv", "tree.json", "tree.csv"):
            rel = str(directory / name)
            if rel not in inventories["outputs"]:
                problems.append(f"outputs: inventory is missing {rel}")
    for section, folder in (("evidence", "evidence"), ("outputs", "output/snapshot"),
                            ("outputs", "output/safe-txs"), ("outputs", "output/push-plan")):
        for file in (k.KIT / folder).rglob("*"):
            if file.is_file() and str(file.relative_to(k.KIT)) not in inventories[section]:
                problems.append(f"{section}: inventory is missing {file.relative_to(k.KIT)}")
    for section, entries in inventories.items():
        for rel, digest in entries.items():
            if (not isinstance(rel, str) or Path(rel).is_absolute() or ".." in Path(rel).parts
                    or not (k.KIT / rel).resolve().is_relative_to(k.KIT.resolve())):
                problems.append(f"{section}: invalid artifact path {rel}")
                continue
            path = k.KIT / rel
            if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
                problems.append(f"{section}: {rel} has an invalid sha256")
            elif not path.is_file():
                problems.append(f"{section}: {rel} is missing")
            elif sha(path) != digest:
                problems.append(f"{section}: {rel} does not match its recorded sha256")
    return problems


def regenerate(rpc: str, snapshot_rpc: str, manifest: dict) -> list[str]:
    """Reruns the deterministic phases whose inputs are recorded and requires byte identity. The deploy plan
    records the block its fork is at, so it must regenerate on the pinned fork; the snapshots need the fork that
    holds the vault's deposits."""
    problems = []
    runs = [["python3.14", "kit/deploy_plan.py", "--rehearsal", "--rpc", rpc]]
    snapshots = sorted({Path(rel).parts[2] for rel in manifest.get("outputs", {}) if rel.startswith("output/snapshot/")})
    for block in snapshots:
        recorded = json.loads((k.OUTPUT / "snapshot" / block / "snapshot.json").read_text())
        # Rescan from the recorded first block: the vault's deploy-block search bisects historical state, which a
        # long-running private anvil does not keep, and the scan range is part of the recorded snapshot anyway.
        runs.append(["python3.14", "kit/snapshot.py", "--rehearsal", "--block", block, "--vault", recorded["vault"],
                     "--from-block", str(recorded["scannedFromBlock"]), "--rpc", snapshot_rpc])
    for argv in runs:
        result = subprocess.run(argv, cwd=k.PROJECT, capture_output=True, text=True)
        if result.returncode != 0:
            problems.append(f"regen {' '.join(argv[1:3])}: exited {result.returncode}: {k.scrub(result.stderr[-400:])}")
    for rel, digest in manifest.get("outputs", {}).items():
        if (rel.startswith("output/deploy/") or rel.startswith("output/snapshot/")) and (k.KIT / rel).is_file():
            if sha(k.KIT / rel) != digest:
                problems.append(f"regen: {rel} is not byte-identical to the recorded output")
    return problems


def main() -> None:
    ap = argparse.ArgumentParser(description="Launch kit check: hashes, open decisions, byte-identical regen.")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--regen", action="store_true")
    ap.add_argument("--rpc")
    ap.add_argument("--snapshot-rpc")
    args = ap.parse_args()
    if args.write:
        k.write_json(MANIFEST, build_manifest())
        print(f"wrote {MANIFEST.relative_to(k.PROJECT)}")
        return
    if not MANIFEST.is_file():
        k.fail("kit/manifest.json is missing; run with --write after reviewing the kit")
    manifest = json.loads(MANIFEST.read_text())
    problems = check_hashes(manifest) + check_tbds()
    if args.regen:
        rpc = k.rpc_url(args.rpc)
        problems += regenerate(rpc, args.snapshot_rpc or rpc, manifest)
    counts = {s: len(manifest.get(s, {})) for s in ("committed", "evidence", "outputs")}
    if problems:
        print("KIT CHECK FAILED")
        for p in problems:
            print(f"  - {p}")
        sys.exit(1)
    print(f"KIT CHECK OK: {counts['committed']} committed artifacts, {counts['evidence']} evidence files, "
          f"{counts['outputs']} recorded outputs match their sha256")
    print(f"  open decisions (params.json TBD) = exactly the {len(SPEC_6)} remaining spec §6 keys:")
    for key, what in SPEC_6.items():
        print(f"    {key}: {what}")
    print("  decided, and held at the decided value in both params files:")
    for key, (value, why) in DECIDED.items():
        print(f"    {key} = {value!r}: {why}")
    if args.regen:
        print("  regenerated deploy plan + snapshots: byte-identical")


if __name__ == "__main__":
    main()
