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
import time
import urllib.error
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


# A request the RPC rate-limits is sent again after each of these waits, in seconds; after the last, the phase stops.
# Batches reach a plan's limit, and so does the single call sent right after one.
RATE_LIMIT_WAITS = (1, 2, 4, 8, 16, 32)
STILL_LIMITED = f"still rate-limited after {len(RATE_LIMIT_WAITS)} more tries over {sum(RATE_LIMIT_WAITS)} s"
# How an entry of a batch says "rate-limited": the HTTP status used as a JSON-RPC error code, and EIP-1474's "limit
# exceeded". Read that way only in a batch of eth_calls: for eth_getLogs some providers use -32005 for a result cap.
RATE_LIMIT_CODES = (429, -32005)


def rate_limited(reply) -> bool:
    """Whether a batch's reply is a rate limit: HTTP 429 (None here), or any error in it with a rate-limit code."""
    entries = reply if isinstance(reply, list) else [reply]
    return reply is None or any(isinstance(e, dict) and isinstance(e.get("error"), dict)
                                and e["error"].get("code") in RATE_LIMIT_CODES for e in entries)


def provider_reason(raw: bytes) -> str:
    """The provider's own words for a refused request, scrubbed of URLs."""
    text = raw.decode(errors="replace")
    try:
        message = json.loads(text)["error"]["message"]
        if isinstance(message, str):
            text = message
    except (ValueError, KeyError, TypeError):
        pass
    return scrub(" ".join(text.split()))[:240]


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

    def try_call(self, method: str, params: list) -> tuple[bool, object, str]:
        """One call that reports any failure instead of stopping: (served, result, the reason). For the probes that
        ask what an RPC serves, where every failure means it does not: a JSON-RPC error, an HTTP error status
        (providers put the reason in its body: free tiers refuse wide log ranges with a 400, partial-archive nodes
        old state with a 403), a transport failure or an unparsable body."""
        outcome, result, reason = self._try(method, params)
        return outcome == "served", result, reason

    def call_or_refusal(self, method: str, params: list) -> tuple[bool, object, str]:
        """One call that reports the provider's own refusal instead of stopping: (served, result, the provider's
        reason). For a caller that answers a refusal by asking for less. Any other failure stops the phase, as
        call() does: it says nothing about the request."""
        outcome, result, reason = self._try(method, params)
        if outcome == "limited":
            fail(f"rpc {method}: {STILL_LIMITED}: {reason}")
        if outcome == "failed":
            fail(f"rpc {method}: {reason}")
        return outcome == "served", result, reason

    def _try(self, method: str, params: list) -> tuple[str, object, str]:
        """One call that never stops the phase: ("served", result, "") or one of these with its reason, scrubbed of
        URLs. A rate limit is sent again after each of RATE_LIMIT_WAITS first.
        - "refused": the provider read the request and declined it, with a JSON-RPC error in an HTTP 200 or in the
          body of an HTTP error status other than 401, 403 and 429.
        - "limited": still a rate limit (HTTP 429, or the error code 429) after the last wait.
        - "failed": anything else: a timeout, a transport failure, an unparsable body, an HTTP error status without
          a JSON-RPC error, and 401 and 403, which are about the key.
        A subclass that filters `_request` (the testnet kit's read-only RPC) keeps its filter: the call goes through
        `_request`, so only a JSON-RPC error in its reply is reported."""
        for wait in (*RATE_LIMIT_WAITS, None):
            outcome, result, reason = self._try_once(method, params)
            if outcome != "limited" or wait is None:
                break
            time.sleep(wait)
        return outcome, result, reason

    def _try_once(self, method: str, params: list) -> tuple[str, object, str]:
        status, where, fallback = 200, "", "an empty reply"
        if type(self)._request is not Rpc._request:
            raw = json.dumps(self._request(method, params)).encode()
        else:
            self._id += 1
            request = urllib.request.Request(self._url, json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method,
                                                                    "params": params}).encode(),
                                             {"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(request, timeout=120) as response:
                    raw = response.read()
            except urllib.error.HTTPError as error:
                status, where, fallback = error.code, f"HTTP {error.code}: ", str(error.reason)
                try:
                    raw = error.read()
                except Exception:  # noqa: BLE001
                    raw = b""  # a body that cannot be read leaves the status line as the reason
            except Exception as error:  # noqa: BLE001
                return "failed", None, scrub(str(error))  # no reply: a timeout or a transport failure
        try:
            reply = json.loads(raw)
        except ValueError:
            reply = None
        if status == 200 and isinstance(reply, dict) and "result" in reply and "error" not in reply:
            return "served", reply["result"], ""
        declined = reply.get("error") if isinstance(reply, dict) else None
        reason = where + (provider_reason(raw) or fallback)
        if status == 429 or (isinstance(declined, dict) and declined.get("code") == 429):
            return "limited", None, reason
        if isinstance(declined, dict) and status not in (401, 403):
            return "refused", None, reason
        return "failed", None, reason

    def _request(self, method: str, params: list) -> dict:
        self._id += 1
        payload = {"jsonrpc": "2.0", "id": self._id, "method": method, "params": params}
        reply = self._post(payload, method, none_on_http_429=True)
        for wait in RATE_LIMIT_WAITS:
            if reply is not None:
                break
            time.sleep(wait)
            reply = self._post(payload, method, none_on_http_429=True)
        if reply is None:
            fail(f"rpc {method}: {STILL_LIMITED}")
        return reply

    def _post(self, payload: dict | list, what: str, *, none_on_http_429: bool = False):
        request = urllib.request.Request(self._url, json.dumps(payload).encode(), {"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                return json.loads(response.read())
        except Exception as error:  # noqa: BLE001 — any transport failure stops the phase, scrubbed
            if none_on_http_429 and isinstance(error, urllib.error.HTTPError) and error.code == 429:
                return None
            fail(f"rpc {what}: {error}")

    def batch(self, calls: list[tuple[str, list]]) -> list:
        """The results of `calls`, in order, from one JSON-RPC batch request. Stops unless the reply holds exactly
        one successful entry per call. For reads only: a batch the RPC rate-limits, whole or in one entry, is sent
        again, whole, after each of RATE_LIMIT_WAITS. A subclass that filters `_request` (the testnet kit's
        read-only RPC) gets its calls one at a time instead, so its filter still applies."""
        if not calls or type(self)._request is not Rpc._request:
            return [self.call(method, params) for method, params in calls]
        ids = range(self._id + 1, self._id + 1 + len(calls))
        self._id += len(calls)
        what = f"batch of {len(calls)}"
        payload = [{"jsonrpc": "2.0", "id": i, "method": method, "params": params}
                   for i, (method, params) in zip(ids, calls)]
        for wait in (*RATE_LIMIT_WAITS, None):
            reply = self._post(payload, what, none_on_http_429=True)
            if not rate_limited(reply):
                break
            if wait is None:
                fail(f"rpc {what}: {STILL_LIMITED}; send smaller batches (--read-batch)")
            time.sleep(wait)
        if isinstance(reply, dict) and "error" in reply:
            fail(f"rpc {what}: {json.dumps(reply['error'])}")
        entries = {e.get("id"): e for e in reply if isinstance(e, dict)} if isinstance(reply, list) else {}
        if not isinstance(reply, list) or len(reply) != len(calls) or set(entries) != set(ids):
            fail(f"rpc {what}: the reply does not hold exactly one entry per call")
        for i, (method, _) in zip(ids, calls):
            if "error" in entries[i] or "result" not in entries[i]:
                fail(f"rpc {what}: {method}: {json.dumps(entries[i].get('error'))}")
        return [entries[i]["result"] for i in ids]

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


def run_tool(argv: list[str], cwd: Path, env: dict | None = None, timeout: int | None = None,
             on_timeout: str = "") -> str:
    """Runs forge/cast inside `cwd` (so that project's foundry.toml, remappings and fs sandbox apply).
    Stops on a non-zero exit, printing the scrubbed tail of its output, and past `timeout` seconds, naming the tool,
    its script and the limit, then `on_timeout`: what the operator can do about it."""
    try:
        result = subprocess.run(argv, cwd=cwd, env=_tool_env(env), capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        what = " ".join(argv[:3] if argv[1:2] == ["script"] else argv[:2])
        fail(f"{what} did not finish within its {timeout} s limit" + (f". {on_timeout}" if on_timeout else ""))
    if result.returncode != 0:
        fail(f"{argv[0]} {argv[1] if len(argv) > 1 else ''} exited {result.returncode}:\n"
             f"{result.stdout[-4000:]}\n{result.stderr[-4000:]}")
    return scrub(result.stdout)
