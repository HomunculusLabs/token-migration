#!/usr/bin/env python3.14
"""Shared helpers for the launch kit. Standard library only: the kit adds no dependencies.

- Params: load params.json (or params.rehearsal.json) and stop on any "TBD" a phase needs, naming the
  spec §6 decision that blocks it. Nothing is ever defaulted.
- RPC: a small JSON-RPC client. An RPC URL can carry an API key, so it is never printed and every error
  message is scrubbed of it.
- Keccak-256 in pure Python (the algorithm of the rehearsal's mathlib.py), so the independent verifiers
  share no code with forge.
- Output: deterministic JSON (insertion-ordered keys, two-space indent, trailing newline) and no wall-clock
  times, so regenerating an artifact from the same inputs is byte-identical.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request
from urllib.parse import urlsplit
from pathlib import Path
from typing import NoReturn

KIT = Path(__file__).resolve().parent
PROJECT = KIT.parent  # contracts/migration-launch
CONTRACTS = PROJECT.parent  # contracts/
OUTPUT = KIT / "output"  # gitignored; the manifest records sha256 of what matters
TBD = "TBD"

_URL = re.compile(r"(https?|wss?)://[^\s\"'<>]+")


def scrub(text: str) -> str:
    return _URL.sub("<url>", text)


def fail(message: str) -> NoReturn:
    print(f"KIT STOP: {scrub(message)}", file=sys.stderr)
    sys.exit(2)


# ---------------------------------------------------------------------------------------------------------
# Params
# ---------------------------------------------------------------------------------------------------------


def load_params(path: str | Path | None = None) -> dict:
    p = Path(path) if path else KIT / "params.json"
    if not p.is_file():
        fail(f"params file not found: {p}")
    return json.loads(p.read_text())


def load_phase_params(path: str | Path | None = None, *, rehearsal: bool = False) -> dict:
    """Bind phase intent to file contents, not a filename that can be changed."""
    if rehearsal and path is not None:
        fail("choose --rehearsal or --params, not both")
    params = load_params(KIT / "params.rehearsal.json" if rehearsal else path)
    expected = "rehearsal" if rehearsal else "production"
    if params.get("mode") != expected:
        fail(f"params.mode must be {expected}; rehearsal inputs require --rehearsal")
    if not rehearsal and "rehearsalKeys" in params:
        fail("production parameters must not contain rehearsalKeys")
    return params


def require_loopback(url: str) -> None:
    """Only an explicit local HTTP endpoint may receive rehearsal transactions."""
    try:
        parsed = urlsplit(url)
        valid = (parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost", "::1")
                 and parsed.username is None and parsed.password is None
                 and parsed.port is not None and parsed.port > 0 and not parsed.fragment)
    except ValueError:
        valid = False
    if not valid:
        fail("rehearsal transactions require an HTTP loopback RPC with an explicit port and no userinfo")


def tbd_paths(node, prefix: str = "") -> list[str]:
    """Every dotted path under `node` whose value is the literal "TBD"."""
    if isinstance(node, dict):
        return [x for k, v in node.items() for x in tbd_paths(v, f"{prefix}.{k}" if prefix else k)]
    if isinstance(node, list):
        return [x for i, v in enumerate(node) for x in tbd_paths(v, f"{prefix}[{i}]")]
    return [prefix] if node == TBD else []


def get(params: dict, dotted: str):
    node = params
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            fail(f"params: missing key {dotted}")
        node = node[part]
    return node


def need(params: dict, *dotted: str):
    """The values at `dotted`. Stops if any of them is (or contains) a TBD, naming the decision."""
    values, blocked = [], []
    for d in dotted:
        value = get(params, d)
        blocked += tbd_paths(value, d)
        values.append(value)
    if blocked:
        fail("open decisions block this phase: " + "; ".join(f"{b} ({_decision(params, b)})" for b in blocked))
    return values[0] if len(values) == 1 else tuple(values)


def _decision(params: dict, dotted: str) -> str:
    section = params.get(dotted.split(".")[0])
    return section.get("decision", "spec §6") if isinstance(section, dict) else "spec §6"


# ---------------------------------------------------------------------------------------------------------
# RPC
# ---------------------------------------------------------------------------------------------------------


def rpc_url(cli_value: str | None) -> str:
    url = cli_value or os.environ.get("KIT_RPC_URL")
    if not url:
        fail("no RPC: pass --rpc or set KIT_RPC_URL")
    return url


class Rpc:
    def __init__(self, url: str):
        self._url = url
        self._id = 0

    def call(self, method: str, params: list):
        reply = self._request(method, params)
        if "error" in reply:
            fail(f"rpc {method}: {json.dumps(reply['error'])}")
        return reply["result"]

    def call_or_none(self, method: str, params: list):
        """Like call(), but an RPC-level error (e.g. an eth_call revert) returns None instead of stopping."""
        reply = self._request(method, params)
        return None if "error" in reply else reply["result"]

    def _request(self, method: str, params: list) -> dict:
        self._id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params}).encode()
        request = urllib.request.Request(self._url, body, {"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                return json.loads(response.read())
        except Exception as error:  # noqa: BLE001 — any transport failure stops the phase, scrubbed
            fail(f"rpc {method}: {error}")

    def chain_id(self) -> int:
        return int(self.call("eth_chainId", []), 16)

    def block(self, tag: int | str = "latest") -> dict:
        return self.call("eth_getBlockByNumber", [hex(tag) if isinstance(tag, int) else tag, False])

    def eth_call(self, to: str, data: str, block: int | str = "latest") -> str:
        tag = hex(block) if isinstance(block, int) else block
        return self.call("eth_call", [{"to": to, "data": data}, tag])


# ---------------------------------------------------------------------------------------------------------
# Hashing and ABI words
# ---------------------------------------------------------------------------------------------------------

_RC = [
    0x1, 0x8082, 0x800000000000808A, 0x8000000080008000, 0x808B, 0x80000001, 0x8000000080008081,
    0x8000000000008009, 0x8A, 0x88, 0x80008009, 0x8000000A, 0x8000808B, 0x800000000000008B,
    0x8000000000008089, 0x8000000000008003, 0x8000000000008002, 0x8000000000000080, 0x800A,
    0x800000008000000A, 0x8000000080008081, 0x8000000000008080, 0x80000001, 0x8000000080008008,
]
_ROT = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14]
_M64 = (1 << 64) - 1


def _rol(x: int, n: int) -> int:
    return ((x << n) | (x >> ((64 - n) % 64))) & _M64


def keccak(data: bytes) -> bytes:
    """Ethereum Keccak-256 (NOT hashlib.sha3_256, which pads differently)."""
    rate = 136
    padded = bytearray(data)
    pad = rate - len(padded) % rate
    if pad == 1:
        padded.append(0x81)
    else:
        padded += b"\x01" + b"\x00" * (pad - 2) + b"\x80"
    a = [0] * 25
    for offset in range(0, len(padded), rate):
        for i in range(rate // 8):
            a[i] ^= int.from_bytes(padded[offset + 8 * i : offset + 8 * i + 8], "little")
        for rc in _RC:
            c = [a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20] for x in range(5)]
            d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
            for i in range(25):
                a[i] ^= d[i % 5]
            b = [0] * 25
            for y in range(5):
                for x in range(5):
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = _rol(a[x + 5 * y], _ROT[x + 5 * y])
            for y in range(5):
                for x in range(5):
                    a[x + 5 * y] = b[x + 5 * y] ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y])
            a[0] ^= rc
    return b"".join(x.to_bytes(8, "little") for x in a)[:32]


def selector(signature: str) -> bytes:
    return keccak(signature.encode())[:4]


def word(value: int) -> bytes:
    if not 0 <= value < 1 << 256:
        raise ValueError("ABI word out of range")
    return value.to_bytes(32, "big")


def addr_word(address: str) -> bytes:
    return word(int(address, 16))


def checksum(address: str) -> str:
    """EIP-55 mixed-case form of `address`."""
    hex_addr = address.lower().removeprefix("0x")
    if not re.fullmatch(r"[0-9a-f]{40}", hex_addr):
        fail(f"not an address: {address}")
    digest = keccak(hex_addr.encode()).hex()
    return "0x" + "".join(ch.upper() if int(digest[i], 16) >= 8 else ch for i, ch in enumerate(hex_addr))


# ---------------------------------------------------------------------------------------------------------
# Files and tools
# ---------------------------------------------------------------------------------------------------------


def write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2) + "\n")


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _tool_env(extra: dict | None) -> dict:
    env = dict(os.environ)
    env["PATH"] = f"{Path.home() / '.foundry' / 'bin'}:{env.get('PATH', '')}"
    env.update(extra or {})
    return env


def run_tool(argv: list[str], cwd: Path, env: dict | None = None, timeout: int | None = None) -> str:
    """Runs forge/cast inside `cwd` (so that project's foundry.toml, remappings and fs sandbox apply).
    Stops on a non-zero exit, printing the scrubbed tail of its output."""
    result = subprocess.run(argv, cwd=cwd, env=_tool_env(env), capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0:
        fail(f"{argv[0]} {argv[1] if len(argv) > 1 else ''} exited {result.returncode}:\n"
             f"{result.stdout[-4000:]}\n{result.stderr[-4000:]}")
    return scrub(result.stdout)
