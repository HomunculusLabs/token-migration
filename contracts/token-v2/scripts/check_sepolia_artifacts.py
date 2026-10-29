#!/usr/bin/env python3
"""Compile privately; assert Sepolia ABI/selectors/storage parity, report both bytecode hashes.

Bytecode is intentionally DIFFERENT on Sepolia (the chain constant changes PUSH width
and offsets). Production compatibility is separately measured against the pre-change
artifact receipt; this parity gate is not an audit or an equivalence claim about chains.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

from sepolia_source import ROOT, SOURCE, OUTPUT, check


def normalize(value):
    def strip(text):
        return re.sub(r"(t_(?:struct|enum|contract)\([^)]*\))\d+", r"\1", text)
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if isinstance(value, dict):
        return {strip(key): normalize(item) for key, item in value.items() if key not in ("astId", "contract")}
    return strip(value) if isinstance(value, str) else value


def main():
    check(SOURCE.read_text(), OUTPUT.read_text())
    with tempfile.TemporaryDirectory(prefix="sepolia-parity-") as directory:
        tmp = Path(directory)
        result = subprocess.run(["forge", "build", "--deny", "warnings", "--extra-output", "storageLayout",
                                 "--out", str(tmp / "out"), "--cache-path", str(tmp / "cache")],
                                cwd=ROOT, capture_output=True, text=True, check=True)
        artifacts = {name: json.loads((tmp / "out" / (name + ".sol") / (name + ".json")).read_text())
                     for name in ("SurplusTokenV2", "SurplusTokenV2BaseSepolia")}
        production, sepolia = artifacts.values()
        for field in ("abi", "methodIdentifiers", "storageLayout"):
            if normalize(production[field]) != normalize(sepolia[field]):
                raise ValueError("Sepolia artifact parity failed: " + field)
        if normalize(production["storageLayout"]) != json.loads((ROOT / "storage-layout.json").read_text()):
            raise ValueError("production storage-layout snapshot changed")
        report = {"parity": "ABI, selectors and normalized storage layout identical", "artifacts": {}}
        for name, artifact in artifacts.items():
            report["artifacts"][name] = {
                "sourceSha256": hashlib.sha256((ROOT / "src" / (name + ".sol")).read_bytes()).hexdigest(),
                "creationSha256": hashlib.sha256(bytes.fromhex(artifact["bytecode"]["object"][2:])).hexdigest(),
                "runtimeTemplateSha256": hashlib.sha256(bytes.fromhex(artifact["deployedBytecode"]["object"][2:])).hexdigest(),
                "abiSha256": hashlib.sha256(json.dumps(artifact["abi"], sort_keys=True).encode()).hexdigest(),
                "layoutSha256": hashlib.sha256(json.dumps(normalize(artifact["storageLayout"]), sort_keys=True).encode()).hexdigest(),
                "immutableOffsets": list(artifact["deployedBytecode"]["immutableReferences"].values()),
            }
        print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
