#!/usr/bin/env python3.14
"""Launch kit, phase "snapshot": the vault's deposits at one block → deposits.csv → tree → three
independent verifications → the numbers for commitRoot.

    python3.14 kit/snapshot.py --block N --vault 0x… --rpc <fork or archive RPC>
                               [--params kit/params.json | --rehearsal] [--log-chunk 10]

1. Every account that ever deposited is read from the vault's own DepositIssued events up to block N.
   Each account's NET ledger credit (credited − withdrawn) is then read AT block N. Σ net must equal the
   vault's on-chain `totalDepositedV1 − totalLedgerWithdrawnV1` at N. That proves no depositor was missed
   (a missed log would leave a gap) and none was invented.
2. deposits.csv: one row per account with net > 0, amount = net × rateBps / 10 000 (the vault's
   formula), sorted by address. Sorting makes the leaf order, and so the root, reproducible by anyone.
3. migration-tools BuildTree → tree.json + tree.csv.
4. Three checks that share no code path: VerifyTree (migration-tools), VerifyTreeBulk (re-derive and fold
   every stored proof), and verify_tree_py() below (pure-Python Keccak, re-reads the ledger at N).
5. commitRoot inputs: root and total. With pro-rata on, the vault reverts unless total equals
   net × rate / 10 000 over the whole ledger, so the script checks that exact identity too.

Writes kit/output/snapshot/<N>/{deposits.csv, tree.json, tree.csv, snapshot.json}. Nothing is sent to any chain.
"""
import argparse
import csv
import io
import json
import re
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kitlib as k  # noqa: E402

TOOLS = k.CONTRACTS / "migration-tools"
DEPOSIT_ISSUED = "0x" + k.keccak(b"DepositIssued(address,uint256,uint256)").hex()


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Launch kit snapshot: vault deposits at a block -> verified tree.")
    ap.add_argument("--block", type=int, required=True)
    ap.add_argument("--vault", required=True)
    ap.add_argument("--rpc")
    ap.add_argument("--params")
    ap.add_argument("--rehearsal", action="store_true")
    ap.add_argument("--from-block", type=int, help="first block to scan (default: the vault's deploy block)")
    ap.add_argument("--log-chunk", type=int, default=10, help="blocks per eth_getLogs (free-tier RPCs cap at 10)")
    return ap.parse_args()


def load(args) -> dict:
    return k.load_phase_params(args.params, rehearsal=args.rehearsal)


def call_uint(rpc: k.Rpc, to: str, data: bytes, block: int | str) -> int:
    value = rpc.eth_call(to, "0x" + data.hex(), block)
    if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-fA-F]{64}", value):
        k.fail("ledger RPC returned a malformed ABI word")
    return int(value, 16)


def check_block(rpc: k.Rpc, block: int, block_hash: str, *, rehearsal: bool) -> dict:
    def header(value):
        if (not isinstance(value, dict) or not isinstance(value.get("hash"), str)
                or not re.fullmatch(r"0x[0-9a-fA-F]{64}", value["hash"])
                or any(not isinstance(value.get(key), str) or not re.fullmatch(r"0x[0-9a-fA-F]+", value[key])
                       for key in ("number", "timestamp"))):
            k.fail("malformed block header")
        return value
    head = header(rpc.block(block))
    if int(head["number"], 16) != block or head["hash"].lower() != block_hash.lower():
        k.fail("snapshot block is no longer canonical on this RPC")
    if not rehearsal:
        version = rpc.call("web3_clientVersion", [])
        if not isinstance(version, str) or "anvil" in version.lower():
            k.fail("live finality requires a canonical chain RPC, not private Anvil finality")
        finalized = header(rpc.block("finalized"))
        if int(finalized["number"], 16) < block:
            k.fail("snapshot block is not finalized")
    return head


def verify_snapshot(tree_path: Path, rpc: k.Rpc, vault: str, params: dict, *, rehearsal: bool,
                    finality_rpc: k.Rpc | None = None) -> dict:
    """Authenticate metadata against the chain, then re-read every entitlement; saved verdicts are not evidence."""
    path = tree_path.parent / "snapshot.json"
    if not path.is_file():
        k.fail(f"mandatory snapshot missing: {path}")
    try:
        s = json.loads(path.read_text())
        if (s["chainId"] != params["chainId"] or rpc.chain_id() != params["chainId"]
                or k.checksum(s["vault"]) != k.checksum(vault)):
            k.fail("snapshot chain/vault does not match deployment")
        if s["sha256"]["tree.json"] != k.sha256_file(tree_path):
            k.fail("tree hash does not match snapshot")
        block = s["block"]
        if type(block) is not int or block < 0 or not re.fullmatch(r"0x[0-9a-fA-F]{64}", s["blockHash"]):
            k.fail("invalid snapshot block identity")
        head = check_block(rpc, block, s["blockHash"], rehearsal=True)
        authority = finality_rpc or rpc
        if authority.chain_id() != params["chainId"]:
            k.fail("finality RPC chain mismatch")
        check_block(authority, block, s["blockHash"], rehearsal=rehearsal)
        ledger = rpc if rehearsal else authority
        rate, pro_rata = k.need(params, "vault.rateBps", "vault.proRata")
        actual_rate = call_uint(ledger, vault, k.selector("MIGRATION_RATE_BPS()"), block)
        actual_pro_rata = call_uint(ledger, vault, k.selector("PRO_RATA_ENABLED()"), block)
        deadline = call_uint(ledger, vault, k.selector("DEPOSIT_DEADLINE()"), block)
        if rate != actual_rate or s["rateBps"] != rate or actual_pro_rata != int(pro_rata):
            k.fail("snapshot/params rate or pro-rata mode differs from vault")
        if int(head["timestamp"], 16) != s["blockTimestamp"] or s["blockTimestamp"] <= deadline:
            k.fail("snapshot must be strictly after the deposit deadline")
        expected_deadline = params["vault"]["depositDeadline"]
        if expected_deadline == k.TBD and not rehearsal:
            k.fail("production snapshot requires an approved deposit deadline")
        if expected_deadline != k.TBD and expected_deadline != deadline:
            k.fail("snapshot vault deadline differs from params")
        if (call_uint(ledger, vault, k.selector("phase()"), block) != 0
                or call_uint(ledger, vault, k.selector("claimsEverActive()"), block) != 0
                or call_uint(ledger, vault, k.selector("totalClaimedAmount()"), block) != 0):
            k.fail("snapshot must precede commitment and all payouts")
        verified = verify_tree_py(tree_path, ledger, vault, block, rate)
        if (s["root"].lower() != verified["root"] or int(s["totalClaimable"]) != int(verified["total"])
                or s["leaves"] != verified["leaves"] or int(s["netLedgerV1"]) != int(verified["netLedgerV1"])):
            k.fail("snapshot root/total/leaves/net ledger differ from verified tree")
        if pro_rata and int(verified["total"]) != int(verified["netLedgerV1"]) * rate // 10_000:
            k.fail("tree total differs from pro-rata commit total")
        check_block(rpc, block, s["blockHash"], rehearsal=True)
        check_block(authority, block, s["blockHash"], rehearsal=rehearsal)
        return s | {"verification": verified, "finality": "private-rehearsal-not-finalized" if rehearsal else "finalized"}
    except (KeyError, TypeError, ValueError, OSError) as error:
        k.fail(f"invalid snapshot/tree/RPC data: {error}")


def deploy_block(rpc: k.Rpc, vault: str, block: int) -> int:
    """Binary search for the first block where the vault has code. Needs historical state: an archive node,
    not a pruned node or a long-running anvil (for those, pass --from-block)."""
    if rpc.call("eth_getCode", [vault, hex(block)]) in ("0x", "0x0"):
        k.fail(f"no vault code at {vault} at block {block}")
    lo, hi = 0, block
    while lo < hi:
        mid = (lo + hi) // 2
        code = rpc.call_or_none("eth_getCode", [vault, hex(mid)])
        if code is None:
            k.fail(f"the RPC has no state at block {mid}; pass --from-block <a block at or before the vault's deployment>")
        if code in ("0x", "0x0"):
            lo = mid + 1
        else:
            hi = mid
    return lo


def depositors(rpc: k.Rpc, vault: str, start: int, end: int, chunk: int) -> list[str]:
    if not 0 <= start <= end or not 1 <= chunk <= 10_000 or (end - start + chunk) // chunk > 10_000:
        k.fail("depositor scan exceeds bounded pagination; check --from-block/--log-chunk")
    seen: dict[str, None] = {}
    block = start
    count = 0
    while block <= end:
        last = min(block + chunk - 1, end)
        logs = rpc.call("eth_getLogs", [{"address": vault, "fromBlock": hex(block), "toBlock": hex(last),
                                          "topics": [DEPOSIT_ISSUED]}])
        if not isinstance(logs, list):
            k.fail("malformed depositor log response")
        count += len(logs)
        if count > 1_000_000:
            k.fail("depositor logs exceed bounded event limit")
        for log in logs:
            try:
                topics = log["topics"]
                if (log["address"].lower() != vault.lower() or log["removed"] is not False
                        or not block <= int(log["blockNumber"], 16) <= last or len(topics) != 2
                        or topics[0].lower() != DEPOSIT_ISSUED
                        or not re.fullmatch(r"0x0{24}[0-9a-fA-F]{40}", topics[1])
                        or not re.fullmatch(r"0x[0-9a-fA-F]{128}", log["data"])):
                    k.fail("malformed DepositIssued event")
                seen["0x" + topics[1][-40:].lower()] = None
            except (KeyError, TypeError, ValueError, AttributeError) as error:
                k.fail(f"malformed depositor RPC result: {error}")
        block = last + 1
    return list(seen)


def main() -> None:
    args = parse_args()
    params = load(args)
    # The ratio and the pro-rata switch are the only params the tree depends on. The deadline is read from
    # the vault itself, then checked against params once §6.3 is decided.
    rate, pro_rata = k.need(params, "vault.rateBps", "vault.proRata")
    rpc = k.Rpc(k.rpc_url(args.rpc))
    if rpc.chain_id() != params["chainId"]:
        k.fail(f"RPC chainId {rpc.chain_id()} != params.chainId {params['chainId']}")
    head = rpc.block(args.block)
    if head is None:
        k.fail(f"block {args.block} not found")
    check_block(rpc, args.block, head["hash"], rehearsal=args.rehearsal)
    vault = k.checksum(args.vault)
    v = params["vault"]

    # The vault must be the one params describe, or the tree would be built against another deal.
    if rpc.call("eth_getCode", [vault, hex(args.block)]) in ("0x", "0x0"):
        k.fail(f"no contract at {vault} at block {args.block}")
    probe = rpc.call_or_none("eth_call", [{"to": vault, "data": "0x" + k.selector("MIGRATION_RATE_BPS()").hex()},
                                          hex(args.block)])
    if probe is None or len(probe) != 66:
        k.fail(f"{vault} is not a MigrationVault (MIGRATION_RATE_BPS() did not return one word)")
    on_chain_rate = call_uint(rpc, vault, k.selector("MIGRATION_RATE_BPS()"), args.block)
    on_chain_pro_rata = call_uint(rpc, vault, k.selector("PRO_RATA_ENABLED()"), args.block) == 1
    if on_chain_rate != rate or on_chain_pro_rata != pro_rata:
        k.fail(f"vault rate/proRata ({on_chain_rate}, {on_chain_pro_rata}) != params ({rate}, {pro_rata})")
    deadline = call_uint(rpc, vault, k.selector("DEPOSIT_DEADLINE()"), args.block)
    block_time = int(head["timestamp"], 16)
    if block_time <= deadline:
        k.fail(f"block {args.block} (t={block_time}) is not after DEPOSIT_DEADLINE {deadline}: the ledger can "
               "still change, so a tree built here could be stale")
    if v.get("depositDeadline") == k.TBD:
        print(f"note: params vault.depositDeadline is TBD (§6.3); using the vault's own DEPOSIT_DEADLINE {deadline}")
    elif v.get("depositDeadline") != deadline:
        k.fail(f"vault DEPOSIT_DEADLINE {deadline} != params vault.depositDeadline {v['depositDeadline']}")

    start = args.from_block if args.from_block is not None else deploy_block(rpc, vault, args.block)
    accounts = depositors(rpc, vault, start, args.block, args.log_chunk)
    rows, net_sum = [], 0
    for account in accounts:
        credited = call_uint(rpc, vault, k.selector("credited(address)") + k.addr_word(account), args.block)
        withdrawn = call_uint(rpc, vault, k.selector("withdrawn(address)") + k.addr_word(account), args.block)
        net = credited - withdrawn
        net_sum += net
        if net > 0:
            rows.append((account.lower(), net * rate // 10_000))
    total_deposited = call_uint(rpc, vault, k.selector("totalDepositedV1()"), args.block)
    total_withdrawn = call_uint(rpc, vault, k.selector("totalLedgerWithdrawnV1()"), args.block)
    if net_sum != total_deposited - total_withdrawn:
        k.fail(f"Σ net over {len(accounts)} depositors = {net_sum} but the vault's net ledger is "
               f"{total_deposited - total_withdrawn}: a depositor is missing from the logs")
    if not rows:
        k.fail("no depositor holds a net credit at this block")
    rows.sort()
    total = sum(amount for _, amount in rows)
    commit_total = (total_deposited - total_withdrawn) * rate // 10_000
    if pro_rata and total != commit_total:
        # Only possible at a non-1:1 rate, where per-leaf flooring loses wei the vault's total check keeps.
        k.fail(f"Σ leaves {total} != vault commit total {commit_total}; commitRoot would revert ProRataTotalMismatch")

    out = k.OUTPUT / "snapshot" / str(args.block)
    out.mkdir(parents=True, exist_ok=True)
    buf = io.StringIO()
    writer = csv.writer(buf, lineterminator="\n")
    writer.writerow(["account", "amount"])
    writer.writerows([(k.checksum(a), str(amount)) for a, amount in rows])
    (out / "deposits.csv").write_text(buf.getvalue())

    root, checks = build_and_verify(out)
    py = verify_tree_py(out / "tree.json", rpc, vault, args.block, rate)
    checks["python"] = py
    if root != py["root"]:
        k.fail(f"python root {py['root']} != BuildTree root {root}")

    snapshot = {
        "chainId": params["chainId"],
        "block": args.block,
        "blockHash": head["hash"],
        "blockTimestamp": block_time,
        "vault": vault,
        "rateBps": rate,
        "scannedFromBlock": start,
        "depositors": len(accounts),
        "leaves": len(rows),
        "netLedgerV1": str(total_deposited - total_withdrawn),
        "root": root,
        "totalClaimable": str(total),
        "commitRoot": {"to": vault, "function": "commitRoot(bytes32,uint256)", "args": [root, str(total)],
                       "data": "0x" + (k.selector("commitRoot(bytes32,uint256)") + bytes.fromhex(root[2:])
                                       + k.word(total)).hex()},
        "sha256": {name: k.sha256_file(out / name) for name in ("deposits.csv", "tree.json", "tree.csv")},
        "checks": checks,
    }
    check_block(rpc, args.block, head["hash"], rehearsal=args.rehearsal)
    snapshot["finality"] = "private-rehearsal-not-finalized" if args.rehearsal else "finalized"
    k.write_json(out / "snapshot.json", snapshot)
    print(f"snapshot at block {args.block}: {len(rows)} leaves, total {total}, root {root}")
    for name, result in checks.items():
        print(f"  {name}: {result['verdict']}")
    print(f"  wrote {out.relative_to(k.PROJECT)}/{{deposits.csv,tree.json,tree.csv,snapshot.json}}")


def build_and_verify(out: Path) -> tuple[str, dict]:
    """Runs BuildTree, VerifyTree and VerifyTreeBulk in migration-tools (their fs sandbox is input/ and
    output/), then copies the tree back. Any failing check stops the phase."""
    inp, tools_out = TOOLS / "input", TOOLS / "output"
    inp.mkdir(exist_ok=True)
    tools_out.mkdir(exist_ok=True)
    for stale in (inp / "deposits.csv", inp / "claims.csv", tools_out / "tree.json", tools_out / "tree.csv"):
        stale.unlink(missing_ok=True)
    shutil.copyfile(out / "deposits.csv", inp / "deposits.csv")
    checks = {}
    k.run_tool(["forge", "script", "script/BuildTree.s.sol", "--tc", "BuildTree"], TOOLS, timeout=590)
    for name, script, contract in (("VerifyTree", "script/VerifyTree.s.sol", "VerifyTree"),
                                   ("VerifyTreeBulk", "script/VerifyTreeBulk.s.sol", "VerifyTreeBulk")):
        # The scripts report through `Log` events, which forge prints only in the -vvvv trace.
        trace = k.run_tool(["forge", "script", script, "--tc", contract, "-vvvv"], TOOLS, timeout=590)
        log = [m.group(1) for m in re.finditer(r'emit Log\(message: "([^"]*)"\)', trace)]
        if not any(line.startswith("OK:") for line in log):
            k.fail(f"{name} did not report OK")
        checks[name] = {"verdict": "OK", "log": log}
    for name in ("tree.json", "tree.csv"):
        shutil.copyfile(tools_out / name, out / name)
    root = json.loads((out / "tree.json").read_text())["root"].lower()
    return root, checks


def verify_tree_py(tree_path: Path, rpc: k.Rpc, vault: str, block: int, rate: int) -> dict:
    """Third check, sharing no code with forge: pure-Python leaf/node hashing, the root, every stored proof
    folded, and every leaf tied back to the vault's own ledger at `block` (net × rate / 10 000)."""
    tree = json.loads(tree_path.read_text())
    leaves = tree["leaves"]
    if not leaves or len(leaves) != tree["leafCount"]:
        k.fail("python: leafCount mismatch")

    def leaf(i: int, account: str, amount: int) -> bytes:
        return k.keccak(k.word(i) + bytes.fromhex(account[2:]) + k.word(amount))

    def node(a: bytes, b: bytes) -> bytes:
        return k.keccak(a + b if a < b else b + a)

    hashes, total, net_sum, previous = [], 0, 0, ""
    for i, entry in enumerate(leaves):
        account, amount = entry["account"].lower(), int(entry["amount"])
        if (entry["index"] != i or account <= previous or amount <= 0
                or not re.fullmatch(r"0x[0-9a-f]{40}", account)):
            k.fail(f"python: leaf {i} out of order")
        credited = call_uint(rpc, vault, k.selector("credited(address)") + k.addr_word(account), block)
        withdrawn = call_uint(rpc, vault, k.selector("withdrawn(address)") + k.addr_word(account), block)
        if credited < withdrawn or amount != (credited - withdrawn) * rate // 10_000:
            k.fail(f"python: leaf {i} ({account}) amount {amount} != ledger at block {block}")
        net_sum += credited - withdrawn
        hashes.append(leaf(i, account, amount))
        total += amount
        previous = account
    net = (call_uint(rpc, vault, k.selector("totalDepositedV1()"), block)
           - call_uint(rpc, vault, k.selector("totalLedgerWithdrawnV1()"), block))
    if net_sum != net:
        k.fail("python: leaf ledger sum != vault net ledger; omitted depositor")
    level = list(hashes)
    while len(level) > 1:
        level = [node(level[j], level[j + 1]) if j + 1 < len(level) else level[j] for j in range(0, len(level), 2)]
    root = "0x" + level[0].hex()
    if root != tree["root"].lower() or total != int(tree["total"]):
        k.fail(f"python: root/total mismatch ({root}, {total})")
    for i, entry in enumerate(leaves):
        h = hashes[i]
        for sibling in entry["proof"]:
            h = node(h, bytes.fromhex(sibling[2:]))
        if "0x" + h.hex() != root:
            k.fail(f"python: proof {i} does not fold to the root")
    return {"verdict": "OK", "root": root, "total": str(total), "leaves": len(leaves),
            "netLedgerV1": str(net), "note": "pure-Python keccak; every leaf == vault ledger at the block x rate; every proof folds"}


if __name__ == "__main__":
    main()
