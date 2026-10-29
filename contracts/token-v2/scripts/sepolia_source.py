#!/usr/bin/env python3
"""Generate the Sepolia-only sibling. Production source is never written.

The checked-in output has exactly two substitutions; do not hand-edit it. CI uses
--check, never --write, so production changes require an explicit regeneration.
"""
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/SurplusTokenV2.sol"
OUTPUT = ROOT / "src/SurplusTokenV2BaseSepolia.sol"
REPLACEMENTS = (
    ("contract SurplusTokenV2 is", "contract SurplusTokenV2BaseSepolia is"),
    ("uint256 public constant CANONICAL_CHAIN_ID = 8453;",
     "uint256 public constant CANONICAL_CHAIN_ID = 84532;"),
)


def render(source: str) -> str:
    for old, new in REPLACEMENTS:
        if source.count(old) != 1 or new in source:
            raise ValueError("production source shape changed; review generation rule")
        source = source.replace(old, new)
    return source


def check(source: str, generated: str) -> None:
    if render(source) != generated:
        raise ValueError("Sepolia source parity failed; review production diff, then regenerate with --write")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    args = parser.parse_args()
    source = SOURCE.read_text()
    if args.write:
        OUTPUT.write_text(render(source))
    else:
        check(source, OUTPUT.read_text())
    print("Sepolia source parity OK: identifier + 84532 only; production source untouched")


if __name__ == "__main__":
    main()
