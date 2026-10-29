#!/usr/bin/env python3.14
"""Launch kit, phase "snapshot-plan": fit the snapshot to the real deposit window, prove the RPC serves it,
then print or run the exact snapshot command.

    python3.14 kit/snapshot_plan.py --vault 0x… [--block N] [--from-block S] [--log-chunk C] [--run]
                                    [--params kit/params.json | --rehearsal] [--rpc R]
    python3.14 kit/snapshot_plan.py --probe [--window-days 30] [--rpc R]

The snapshot finds depositors through eth_getLogs pages of --log-chunk blocks and stops past 10,000 pages.
Its default page, 10 blocks, therefore covers 100,000 blocks: about 2.3 days of Base's 2-second blocks. A
30-day window needs pages of at least 130 blocks, from an RPC that serves ranges that wide.

Launch day (--vault): the snapshot block is the newest finalized block, which must come after the vault's
DEPOSIT_DEADLINE (or --block). The scan starts at the vault's deploy block, found the way snapshot.py finds
it (or --from-block). The page size is the smallest that fits 10,000 pages, raised to 2,000 blocks when the
RPC serves that (or --log-chunk). The snapshot's own depositor scan then runs over the whole range at that
size, so a page the RPC refuses stops here, not an hour into the snapshot. It prints the snapshot command,
how long the snapshot and the later ledger re-reads take, and the time left before COMMIT_DEADLINE. --run
then runs that command. Exit status 3: no finalized block is past the deposit deadline yet.

Before launch (--probe): the same checks for a candidate RPC against Base today, over the most recent
--window-days of finalized blocks: the widest page it serves, the full-window scan (on v1, which never emits
DepositIssued), the archive state the deploy-block search and the later re-reads need, and push-plan's
page size. Exit status 1: the RPC cannot serve that window.

Nothing is written and nothing is sent. The RPC URL is never printed.
"""
import argparse
import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kitlib as k  # noqa: E402
import snapshot  # noqa: E402

MAX_PAGES = 10_000  # snapshot.depositors and push_plan.reconcile both stop past this many pages
PREFERRED_CHUNK = 2_000  # the full-scale rehearsal's page size: few requests, small responses
SPANS = (10_000, 5_000, 2_000, 1_000, 500, 200, 100, 10)  # page widths probed, widest first
PUSH_PLAN_CHUNK = 1_000  # push_plan.py's default --log-chunk
SNAPSHOT_CALLS_PER_DEPOSITOR = 4  # credited + withdrawn per depositor, then both again per leaf (verify_tree_py)
RECHECK_CALLS_PER_LEAF = 2  # safe-txs commit-root and every push-plan run re-read each leaf (verify_snapshot)
NOT_SERVED = 1
NOT_READY = 3


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Launch kit snapshot plan: size and dry-run the depositor scan.")
    ap.add_argument("--vault", help="launch day: the deployed vault")
    ap.add_argument("--probe", action="store_true", help="before launch: test an RPC against Base today")
    ap.add_argument("--window-days", type=float, default=30.0, help="--probe: the deposit window (§6.3)")
    ap.add_argument("--block", type=int, help="snapshot block (default: the newest finalized block)")
    ap.add_argument("--from-block", type=int, help="first block to scan (default: the vault's deploy block)")
    ap.add_argument("--log-chunk", type=int, help="page size instead of the planned one")
    ap.add_argument("--run", action="store_true", help="run the planned snapshot command")
    ap.add_argument("--rpc")
    ap.add_argument("--params")
    ap.add_argument("--rehearsal", action="store_true")
    args = ap.parse_args(argv)
    if bool(args.vault) == args.probe:
        ap.error("pass exactly one of --vault (launch day) and --probe (before launch)")
    if args.probe and (args.run or args.rehearsal
                       or any(v is not None for v in (args.block, args.from_block, args.log_chunk))):
        ap.error("--probe takes only --window-days, --rpc and --params")
    return args


def min_chunk(start: int, end: int) -> int:
    """The smallest --log-chunk the snapshot accepts for blocks [start, end]."""
    return -(-(end - start + 1) // MAX_PAGES)


def page_count(start: int, end: int, chunk: int) -> int:
    return (end - start + chunk) // chunk  # snapshot.depositors' own count


def provider_reason(raw: bytes) -> str:
    """The provider's own words for a refused request, scrubbed of URLs."""
    text = raw.decode(errors="replace")
    try:
        message = json.loads(text)["error"]["message"]
        if isinstance(message, str):
            text = message
    except (ValueError, KeyError, TypeError):
        pass
    return k.scrub(" ".join(text.split()))[:240]


def try_call(url: str, method: str, params: list) -> tuple[bool, object, str]:
    """One JSON-RPC call on kitlib's transport that reports a refusal instead of stopping: (served, result, the
    provider's reason). kitlib's Rpc stops on a refusal and drops the reason, which providers put in the HTTP
    error body (free tiers refuse wide log ranges with a 400, partial-archive nodes old state with a 403)."""
    request = urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                                                      "params": params}).encode(), {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        return False, None, f"HTTP {error.code}: {provider_reason(error.read())}"
    except Exception as error:  # noqa: BLE001 — any transport failure means the call was not served
        return False, None, k.scrub(str(error))
    try:
        reply = json.loads(raw)
    except ValueError:
        return False, None, provider_reason(raw)
    if isinstance(reply, dict) and "result" in reply and "error" not in reply:
        return True, reply["result"], ""
    return False, None, provider_reason(raw)


def logs_served(url: str, address: str, first: int, last: int) -> tuple[bool, str]:
    """Whether the RPC serves one DepositIssued page [first, last] for `address`, and why not."""
    ok, result, reason = try_call(url, "eth_getLogs", [{"address": address, "fromBlock": hex(first),
                                                         "toBlock": hex(last), "topics": [snapshot.DEPOSIT_ISSUED]}])
    return (True, "") if ok and isinstance(result, list) else (False, reason or "malformed eth_getLogs result")


def state_served(url: str, address: str, block: int) -> tuple[bool, str]:
    """Whether the RPC still holds state at `block`, and why not."""
    ok, result, reason = try_call(url, "eth_getCode", [address, hex(block)])
    return (True, "") if ok and isinstance(result, str) else (False, reason or "malformed eth_getCode result")


def widest_page(served, end: int) -> tuple[int, str]:
    """The widest of SPANS that `served(first, last)` accepts for a page ending at `end` (0 if none), and the
    reason given for the first refusal."""
    refusal = ""
    for span in SPANS:
        ok, reason = served(max(0, end - span + 1), end)
        if ok:
            return span, refusal
        refusal = refusal or reason
    return 0, refusal


def call_seconds(rpc: k.Rpc, to: str, data: bytes, block: int, samples: int = 5) -> float:
    """Median seconds for one eth_call: the unit of the snapshot's sequential ledger reads."""
    times = []
    for _ in range(samples):
        started = time.monotonic()
        rpc.eth_call(to, "0x" + data.hex(), block)
        times.append(time.monotonic() - started)
    return statistics.median(times)


def utc(timestamp: int) -> str:
    return datetime.fromtimestamp(timestamp, timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def duration(seconds: float) -> str:
    total = max(0, round(seconds))
    days, rest = divmod(total, 86_400)
    hours, rest = divmod(rest, 3_600)
    minutes, secs = divmod(rest, 60)
    parts = [(days, "d"), (hours, "h"), (minutes, "m")] + ([(secs, "s")] if total < 3_600 else [])
    return " ".join(f"{n}{unit}" for n, unit in parts if n) or "0s"


def canonical_client(rpc: k.Rpc, *, rehearsal: bool) -> str:
    client = rpc.call("web3_clientVersion", [])
    if not isinstance(client, str):
        k.fail("malformed web3_clientVersion")
    if not rehearsal and "anvil" in client.lower():
        k.fail("this needs the canonical Base RPC, not a private anvil (use --rehearsal for a fork)")
    return client


def plan(args, params: dict, rpc: k.Rpc, served, state) -> dict:
    """The checked inputs of the snapshot command. `served(first, last)` reports whether the RPC serves a
    DepositIssued page for the vault and `state(block)` whether it still holds state there. Stops (or exits
    NOT_READY) rather than plan a snapshot that would fail."""
    if rpc.chain_id() != params["chainId"]:
        k.fail(f"RPC chainId {rpc.chain_id()} != params.chainId {params['chainId']}")
    client = canonical_client(rpc, rehearsal=args.rehearsal)
    vault = k.checksum(args.vault)
    if rpc.call("eth_getCode", [vault, "latest"]) in ("0x", "0x0"):
        k.fail(f"no contract at {vault}")

    def read(signature: str) -> int:
        return snapshot.call_uint(rpc, vault, k.selector(signature), "latest")

    deadline, commit_deadline = read("DEPOSIT_DEADLINE()"), read("COMMIT_DEADLINE()")
    if read("phase()") != 0 or read("root()") != 0:
        k.fail("the vault is no longer Open or already has a root: the snapshot comes before commitRoot")
    now = int(rpc.block("latest")["timestamp"], 16)
    if now > commit_deadline:
        k.fail(f"COMMIT_DEADLINE ({utc(commit_deadline)}) has passed: commitRoot reverts, so the only way out is "
               "expireCommit and refunds (RUNBOOK.md, abort paths)")
    finalized = rpc.block("finalized")
    head = finalized if args.block is None else rpc.block(args.block)
    if head is None:
        k.fail(f"block {args.block} not found")
    block, block_time = int(head["number"], 16), int(head["timestamp"], 16)
    if block_time <= deadline:
        if args.block is not None:
            k.fail(f"block {block} ({utc(block_time)}) is not after DEPOSIT_DEADLINE ({utc(deadline)})")
        print(f"not yet: DEPOSIT_DEADLINE is {utc(deadline)} and the newest finalized block, {block:,}, is from "
              f"{utc(block_time)}. Finality runs {duration(now - block_time)} behind the head, so the first "
              "usable block finalizes about that long after the deadline. Run this again then.")
        sys.exit(NOT_READY)
    if not args.rehearsal and block > int(finalized["number"], 16):
        k.fail(f"block {block} is not finalized yet (finalized head {int(finalized['number'], 16)})")
    if args.from_block is None:
        ok, reason = state(block // 2)  # where snapshot.deploy_block's bisection starts
        if not ok:
            k.fail(f"this RPC has no state at block {block // 2:,} ({reason}), which the deploy-block search needs: "
                   "pass --from-block with the vault's deploy block, from its deployment receipt")
        start = snapshot.deploy_block(rpc, vault, block)
    else:
        start = args.from_block
    if not 0 <= start <= block:
        k.fail(f"--from-block {start} is not at or before the snapshot block {block}")
    need = min_chunk(start, block)
    if args.log_chunk is not None and need <= args.log_chunk:
        # An explicit page size that fits the window is probed directly: widest_page() only samples
        # SPANS, so a provider serving 150-block pages would be declared capable of only the
        # largest sampled span below 150 — a false rejection for a requested chunk between them.
        ok, refusal = served(max(0, block - args.log_chunk + 1), block)
        widest = args.log_chunk if ok else 0
    else:
        widest, refusal = widest_page(served, block)
    if widest < need:
        k.fail(f"the scan covers {block - start + 1:,} blocks, so its pages must be at least {need:,} blocks to stay "
               f"within {MAX_PAGES:,} pages, but this RPC serves {widest:,}-block pages at most ({refusal}). "
               "Use an RPC plan that serves wider eth_getLogs ranges.")
    chunk = args.log_chunk if args.log_chunk is not None else max(need, min(PREFERRED_CHUNK, widest))
    if not need <= chunk <= MAX_PAGES:
        k.fail(f"--log-chunk {chunk} does not fit: the range needs {need:,} to {MAX_PAGES:,}")
    started = time.monotonic()
    accounts = snapshot.depositors(rpc, vault, start, block, chunk)
    scan_seconds = time.monotonic() - started
    first_time = int(rpc.block(start)["timestamp"], 16)
    return {"chainId": params["chainId"], "client": client, "vault": vault, "deadline": deadline,
            "commitDeadline": commit_deadline, "now": now, "block": block, "blockTime": block_time,
            "start": start, "secondsPerBlock": (block_time - first_time) / max(1, block - start),
            "need": need, "widest": widest, "chunk": chunk, "pages": page_count(start, block, chunk),
            "depositors": len(accounts), "scanSeconds": scan_seconds,
            "callSeconds": call_seconds(rpc, vault, k.selector("credited(address)") + k.addr_word(vault), block)}


def snapshot_command(p: dict, args) -> list[str]:
    command = ["--block", str(p["block"]), "--vault", p["vault"], "--from-block", str(p["start"]),
               "--log-chunk", str(p["chunk"])]
    if args.rehearsal:
        command.append("--rehearsal")
    elif args.params:
        command += ["--params", args.params]
    return command


def push_plan_line(widest: int, seconds_per_block: float) -> str:
    if widest >= PUSH_PLAN_CHUNK:
        return f"its default {PUSH_PLAN_CHUNK:,}-block pages are served"
    return (f"{PUSH_PLAN_CHUNK:,}-block pages are refused; --log-chunk {widest:,} covers only "
            f"{duration(widest * MAX_PAGES * seconds_per_block)} of claims after the snapshot block")


def print_plan(p: dict, args) -> list[str]:
    command = snapshot_command(p, args)
    ledger = SNAPSHOT_CALLS_PER_DEPOSITOR * p["depositors"] * p["callSeconds"]
    recheck = RECHECK_CALLS_PER_LEAF * p["depositors"] * p["callSeconds"]
    took = p["scanSeconds"] + ledger
    finality = "private rehearsal, finality not checked" if args.rehearsal else "finalized"
    origin = "--from-block" if args.from_block is not None else "the vault's deploy block"
    print(f"snapshot plan: vault {p['vault']} on chain {p['chainId']} ({p['client']})")
    print(f"  deposit deadline  {utc(p['deadline'])}")
    print(f"  snapshot block    {p['block']:,} at {utc(p['blockTime'])} ({finality}, after the deadline)")
    print(f"  scan              blocks {p['start']:,} to {p['block']:,}: {p['block'] - p['start'] + 1:,} blocks, "
          f"from {origin}")
    print(f"  page size         {p['chunk']:,} blocks ({MAX_PAGES:,} pages need at least {p['need']:,}; this RPC "
          f"serves {p['widest']:,}-block pages)")
    print(f"  dry-run scan      {p['pages']:,} pages in {duration(p['scanSeconds'])}: {p['depositors']:,} depositors")
    print(f"  snapshot time     about {duration(took)}: the scan, then "
          f"{SNAPSHOT_CALLS_PER_DEPOSITOR * p['depositors']:,} sequential ledger reads at "
          f"{p['callSeconds'] * 1000:.0f} ms")
    print(f"  later re-reads    safe-txs commit-root and every push-plan run re-read each leaf: about "
          f"{duration(recheck)} each")
    print(f"  push-plan         {push_plan_line(p['widest'], p['secondsPerBlock'])}")
    print(f"  commit deadline   {utc(p['commitDeadline'])}, {duration(p['commitDeadline'] - p['now'])} after the "
          f"latest block. Before it: this snapshot, a second person's rebuild and commit-root's re-read "
          f"(about {duration(2 * took + recheck)}), then signing")
    rpc_hint = " --rpc <rpc>" if args.rpc else ""
    print("$ python3.14 kit/launch.py snapshot " + " ".join(command) + rpc_hint)
    return command


def probe(args, params: dict, rpc: k.Rpc, served, state) -> list[str]:
    """Prints what a --window-days snapshot needs from this RPC on Base today. Returns the problems that would
    stop it (empty when the RPC can serve it). `served(first, last)` probes a DepositIssued page on v1 and
    `state(block)` whether the RPC still holds state there."""
    if rpc.chain_id() != params["chainId"]:
        k.fail(f"RPC chainId {rpc.chain_id()} != params.chainId {params['chainId']}")
    client = canonical_client(rpc, rehearsal=False)
    v1 = k.checksum(params["external"]["v1"])
    finalized = rpc.block("finalized")
    end, end_time = int(finalized["number"], 16), int(finalized["timestamp"], 16)
    seconds_per_block = (end_time - int(rpc.block(end - 10_000)["timestamp"], 16)) / 10_000
    window = round(args.window_days * 86_400 / seconds_per_block)
    start = end - window + 1
    need = min_chunk(start, end)
    widest, refusal = widest_page(served, end)
    problems = []
    print(f"RPC probe: a {args.window_days:g}-day deposit window on chain {params['chainId']} ({client})")
    print(f"  block time        {seconds_per_block:.3f} s, measured over the last 10,000 finalized blocks")
    print(f"  window            {window:,} blocks ending at finalized block {end:,}: pages of at least "
          f"{need:,} blocks fit {MAX_PAGES:,} pages")
    print(f"  widest page       {widest:,} blocks" + (f"; refused wider: {refusal}" if refusal else ""))
    if widest < need:
        problems.append(f"it serves {widest:,}-block eth_getLogs pages and the window needs {need:,}")
    else:
        chunk = max(need, min(PREFERRED_CHUNK, widest))
        started = time.monotonic()
        snapshot.depositors(rpc, v1, start, end, chunk)
        print(f"  full-window scan  {page_count(start, end, chunk):,} pages of {chunk:,} blocks in "
              f"{duration(time.monotonic() - started)}: the snapshot's own scan, on v1")
    ok, reason = state(start)
    if not ok:
        problems.append(f"no state at block {start:,} ({reason}): commit-root and push-plan re-read the ledger at the "
                        "snapshot block days later, which needs an archive node")
        print(f"  archive state     none at the window start: {reason}")
    else:
        print("  archive state     served at the window start (the re-reads days after the snapshot need it)")
    ok, reason = state(end // 2)
    if not ok:
        print(f"  deploy-block      no state at half the chain height, where its search starts ({reason}): "
              "pass --from-block on launch day")
    else:
        started = time.monotonic()
        found = snapshot.deploy_block(rpc, v1, end)
        print(f"  deploy-block      the search found v1's deploy block, {found:,}, in "
              f"{duration(time.monotonic() - started)}")
    print(f"  push-plan         {push_plan_line(widest, seconds_per_block)}")
    per_call = call_seconds(rpc, v1, k.selector("totalSupply()"), end)
    print(f"  eth_call          {per_call * 1000:.0f} ms each; the snapshot makes {SNAPSHOT_CALLS_PER_DEPOSITOR} per "
          f"depositor, about {duration(SNAPSHOT_CALLS_PER_DEPOSITOR * 1_000 * per_call)} per 1,000 depositors")
    print(("NOT OK: " + "; ".join(problems)) if problems else
          f"OK: this RPC can serve the snapshot of a {args.window_days:g}-day deposit window")
    return problems


def main() -> None:
    args = parse_args()
    params = k.load_phase_params(args.params, rehearsal=args.rehearsal)
    url = k.rpc_url(args.rpc)
    rpc = k.Rpc(url)
    if args.probe:
        v1 = k.checksum(params["external"]["v1"])
        problems = probe(args, params, rpc, lambda a, b: logs_served(url, v1, a, b), lambda b: state_served(url, v1, b))
        sys.exit(NOT_SERVED if problems else 0)
    vault = k.checksum(args.vault)
    command = print_plan(plan(args, params, rpc, lambda a, b: logs_served(url, vault, a, b),
                              lambda b: state_served(url, vault, b)), args)
    if args.run:
        sys.stdout.flush()
        os.execv(sys.executable, [sys.executable, str(k.KIT / "snapshot.py"), *command,
                                  *(["--rpc", args.rpc] if args.rpc else [])])


if __name__ == "__main__":
    main()
