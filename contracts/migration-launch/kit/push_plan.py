#!/usr/bin/env python3.14
"""Launch kit, phase "push-plan": the relayer's Multicall3 batches that push every unclaimed v2 claim.

    python3.14 kit/push_plan.py --tree <tree.json> --rpc <RPC> [--params kit/params.json | --rehearsal]
                                [--deployment kit/output/deploy/deployment.json]
                                [--execute-first N --on-private-anvil]   (rehearsal: send N batches, then replan)

1. Authenticates the adjacent snapshot against the ledger, then reconciles ClaimPaid and ProRataClaimed
   against totalClaimedAmount and the Merkle bitmap at one pinned head. Only active, unpaid claims are planned.
2. Packs the rest into `Multicall3.aggregate3` calls with `allowFailure = true`, so one leaf a holder claimed
   in the meantime cannot sink the batch. `claim()` pays the leaf's account, never the sender, so the relayer
   can neither redirect nor receive anything.
3. Sizes each batch by measurement, not a guess. It adds claims while the batch's `eth_estimateGas` (from the
   relayer, at the pinned head) stays under 90% of 2^24 and its calldata under 90% of 128 KB.
4. Prices the whole push at the RPC's base fee: L2 gas plus the L1 data fee from Base's GasPriceOracle
   (`getL1FeeUpperBound`).

Immutable plans live in kit/output/push-plan/plans/<id>/{plan.json,batch-NNN.calldata}; plan.json is the
current summary. Execution journals and progress.json record actual payouts separately. Resume a journal
with --resume-plan <plans/id/plan.json> --execute-first N --on-private-anvil. Nothing is sent otherwise;
execution refuses non-loopback RPCs and never treats a successful outer receipt as payout evidence.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kitlib as k  # noqa: E402
import snapshot  # noqa: E402

OUT = k.OUTPUT / "push-plan"
GAS_CAP = 1 << 24
CALLDATA_CAP = 128 * 1024
HEADROOM = 0.9  # stay 10% under each per-transaction cap
FIRST_GUESS = 120  # the rehearsal measured 120 claims at 8.4M gas / 92 KB


def enc_claim(index: int, account: str, amount: int, proof: list[str]) -> bytes:
    head = k.selector("claim(uint256,address,uint256,bytes32[])")
    body = k.word(index) + k.addr_word(account) + k.word(amount) + k.word(128) + k.word(len(proof))
    return head + body + b"".join(bytes.fromhex(p[2:]) for p in proof)


def enc_aggregate3(target: str, calls: list[bytes], allow_failure: bool) -> bytes:
    """aggregate3((address target, bool allowFailure, bytes callData)[])."""
    head = k.selector("aggregate3((address,bool,bytes)[])")
    elems, offsets, cursor = [], [], 32 * len(calls)
    for data in calls:
        padded = data + b"\x00" * (-len(data) % 32)
        elem = k.addr_word(target) + k.word(1 if allow_failure else 0) + k.word(96) + k.word(len(data)) + padded
        offsets.append(k.word(cursor))
        elems.append(elem)
        cursor += len(elem)
    return head + k.word(32) + k.word(len(calls)) + b"".join(offsets) + b"".join(elems)


def claimed_flags(rpc: k.Rpc, multicall: str, vault: str, n: int, block: int | str = "latest") -> list[bool]:
    flags: list[bool] = []
    if not 0 <= n <= 100_000:
        k.fail("claim index count exceeds bounded read limit")
    for start in range(0, n, 500):
        calls = [k.selector("isClaimed(uint256)") + k.word(i) for i in range(start, min(start + 500, n))]
        data = enc_aggregate3(vault, calls, False)
        try:
            ret = bytes.fromhex(rpc.eth_call(multicall, "0x" + data.hex(), block)[2:])
            count = len(calls)
            def word(offset):
                return int.from_bytes(ret[offset:offset + 32], "big")
            if len(ret) != 64 + 160 * count or word(0) != 32 or word(32) != count:
                k.fail("partial/malformed isClaimed batch response")
            for j in range(count):
                off = 64 + 32 * count + 128 * j
                if (word(64 + 32*j) != off - 64 or word(off) != 1 or word(off + 32) != 64
                        or word(off + 64) != 32 or word(off + 96) not in (0, 1)):
                    k.fail("malformed or reverted isClaimed result")
                flags.append(word(off + 96) == 1)
        except (TypeError, ValueError):
            k.fail("malformed isClaimed RPC response")
    return flags


def estimate(rpc: k.Rpc, relayer: str, to: str, data: bytes, block: int | str = "latest") -> int | None:
    tag = hex(block) if isinstance(block, int) else block
    result = rpc.call_or_none("eth_estimateGas", [{"from": relayer, "to": to, "data": "0x" + data.hex()}, tag])
    return None if result is None else int(result, 16)


def pack(rpc: k.Rpc, relayer: str, multicall: str, vault: str, pending: list[dict],
         block: int | str = "latest") -> list[dict]:
    """Greedy batches: grow while estimateGas and calldata stay under the headroom, shrink on overflow."""
    batches, i = [], 0
    gas_limit, byte_limit = int(GAS_CAP * HEADROOM), int(CALLDATA_CAP * HEADROOM)
    size = FIRST_GUESS
    while i < len(pending):
        size = max(1, min(size, len(pending) - i))
        while True:
            chunk = pending[i:i + size]
            data = enc_aggregate3(vault, [c["calldata"] for c in chunk], True)
            gas = estimate(rpc, relayer, multicall, data, block) if len(data) <= byte_limit else None
            if gas is not None and gas <= gas_limit and len(data) <= byte_limit:
                break
            if size == 1:
                k.fail(f"a single claim (index {chunk[0]['index']}) does not fit a transaction")
            size = max(1, size * 9 // 10)
        batches.append({"indices": [c["index"] for c in chunk], "data": data, "estimatedGas": gas})
        i += len(chunk)
    return batches


def l1_fee_upper(rpc: k.Rpc, oracle: str, size: int, block: int | str = "latest") -> int:
    data = k.selector("getL1FeeUpperBound(uint256)") + k.word(size + 100)  # + a signed tx envelope
    return snapshot.call_uint(rpc, oracle, data, block)


def require_active(rpc: k.Rpc, vault: str, head: dict) -> None:
    block = int(head["number"], 16)
    def value(sig):
        return snapshot.call_uint(rpc, vault, k.selector(sig), block)
    if (value("phase()") != 1 or value("claimsActive()") != 1 or value("claimsExpired()") != 0
            or value("claimWindowEnd()") < int(head["timestamp"], 16)):
        k.fail("claims are not active at the pinned head")


CLAIM_PAID = "0x" + k.keccak(b"ClaimPaid(uint256,address,uint256)").hex()
PRO_RATA_CLAIMED = "0x" + k.keccak(b"ProRataClaimed(address,uint256)").hex()
MAX_LOG_PAGES = 10_000


def reconcile(rpc: k.Rpc, multicall: str, vault: str, tree: dict, frozen: dict,
              head: dict, chunk: int = 1000) -> dict:
    """Both payout events are delivery receipts; the bitmap alone misses formula claims."""
    require_active(rpc, vault, head)
    end, start = int(head["number"], 16), frozen["block"] + 1
    if not 1 <= chunk <= 10_000 or start > end + 1 or (end - start + chunk) // chunk > MAX_LOG_PAGES:
        k.fail("payout log range exceeds bounded scan; use an appropriate --log-chunk")
    block_hashes, paid, identities = {}, {}, set()
    leaves = tree["leaves"]
    accounts = {lf["account"].lower(): lf for lf in leaves}
    if not leaves or len(accounts) != len(leaves) or len(leaves) > 100_000:
        k.fail("invalid or oversized claim tree")
    total = snapshot.call_uint(rpc, vault, k.selector("totalClaimedAmount()"), end)
    if (rpc.eth_call(vault, "0x" + k.selector("root()").hex(), end).lower() != tree["root"].lower()
            or snapshot.call_uint(rpc, vault, k.selector("totalClaimable()"), end) != int(tree["total"])):
        k.fail("on-chain root/total differs from the ledger-verified tree")
    for first in range(start, end + 1, chunk):
        last = min(first + chunk - 1, end)
        logs = rpc.call("eth_getLogs", [{"address": vault, "fromBlock": hex(first), "toBlock": hex(last),
                                        "topics": [[CLAIM_PAID, PRO_RATA_CLAIMED]]}])
        if not isinstance(logs, list) or len(logs) > len(leaves):
            k.fail("malformed or oversized payout log response")
        for log in logs:
            try:
                topics = log["topics"]
                if (log["removed"] is not False or log["address"].lower() != vault.lower()
                        or not isinstance(topics, list) or len(topics) not in (2, 3)
                        or any(not isinstance(t, str) or not re.fullmatch(r"0x[0-9a-fA-F]{64}", t) for t in topics)
                        or not re.fullmatch(r"0x[0-9a-fA-F]{64}", log["data"])
                        or not re.fullmatch(r"0x[0-9a-fA-F]{64}", log["transactionHash"])):
                    k.fail("malformed payout event")
                merkle = topics[0].lower() == CLAIM_PAID
                if (topics[0].lower() not in (CLAIM_PAID, PRO_RATA_CLAIMED)
                        or len(topics) != (3 if merkle else 2) or int(topics[-1], 16) >= 1 << 160):
                    k.fail("payout event ABI mismatch")
                account = "0x" + topics[-1][-40:].lower()
                lf = accounts.get(account)
                if (lf is None or int(log["data"], 16) != int(lf["amount"])
                        or (merkle and int(topics[1], 16) != lf["index"])):
                    k.fail("payout event differs from account entitlement/index")
                block, log_index = int(log["blockNumber"], 16), int(log["logIndex"], 16)
                if not first <= block <= last or log_index < 0:
                    k.fail("payout log outside requested range")
                if block not in block_hashes:
                    block_hashes[block] = rpc.block(block)["hash"].lower()
                if log["blockHash"].lower() != block_hashes[block]:
                    k.fail("payout log block is not canonical")
                identity = (log["transactionHash"].lower(), log_index)
                if identity in identities or account in paid:
                    k.fail("duplicate payout event/account")
                identities.add(identity)
                paid[account] = {"index": lf["index"], "amount": str(int(log["data"], 16)),
                                 "path": "merkle" if merkle else "pro-rata", "transactionHash": identity[0]}
            except (KeyError, TypeError, ValueError, AttributeError) as error:
                k.fail(f"malformed payout RPC result: {error}")
    if sum(int(p["amount"]) for p in paid.values()) != total:
        k.fail("payout logs do not reconcile to totalClaimedAmount; missing/partial history")
    bitmap = claimed_flags(rpc, multicall, vault, len(leaves), end)
    for lf, flag in zip(leaves, bitmap):
        event = paid.get(lf["account"].lower())
        if flag != bool(event and event["path"] == "merkle"):
            k.fail("Merkle bitmap disagrees with payout event history")
    snapshot.check_block(rpc, frozen["block"], frozen["blockHash"], rehearsal=True)
    snapshot.check_block(rpc, end, head["hash"], rehearsal=True)
    return {"paid": paid, "totalClaimedAmount": str(total), "block": end, "blockHash": head["hash"]}


def plan(args, params: dict, rpc: k.Rpc) -> dict:
    tree = json.loads(Path(args.tree).read_text())
    deployment = json.loads(Path(args.deployment).read_text())
    vault = k.checksum(deployment["vault"])
    head = rpc.block()
    require_active(rpc, vault, head)
    relayer_value = k.need(params, "operators.relayer")
    relayer = k.checksum(str(relayer_value))
    ext = params["external"]
    frozen = snapshot.verify_snapshot(Path(args.tree), rpc, vault, params, rehearsal=args.rehearsal)
    state = reconcile(rpc, ext["multicall3"], vault, tree, frozen, head, getattr(args, "log_chunk", 1000))
    leaves = tree["leaves"]
    flags = [lf["account"].lower() in state["paid"] for lf in leaves]
    pending = [{"index": lf["index"], "account": lf["account"], "amount": int(lf["amount"]),
                "calldata": enc_claim(lf["index"], lf["account"], int(lf["amount"]), lf["proof"])}
               for lf, done in zip(leaves, flags) if not done]
    block = int(head["number"], 16)
    batches = pack(rpc, relayer, ext["multicall3"], vault, pending, block) if pending else []
    base_fee = int(head["baseFeePerGas"], 16)
    out_batches, payloads, total_gas, total_l1 = [], {}, 0, 0
    for n, b in enumerate(batches):
        name = f"batch-{n:03d}.calldata"
        payloads[name] = "0x" + b["data"].hex() + "\n"
        l1 = l1_fee_upper(rpc, ext["gasPriceOracle"], len(b["data"]), block)
        total_gas += b["estimatedGas"]
        total_l1 += l1
        out_batches.append({"file": name, "to": k.checksum(ext["multicall3"]), "claims": len(b["indices"]),
                            "firstIndex": b["indices"][0], "lastIndex": b["indices"][-1],
                            "calldataBytes": len(b["data"]), "estimatedGas": b["estimatedGas"],
                            "l1FeeUpperWei": l1, "indices": b["indices"],
                            "sha256": hashlib.sha256(payloads[name].encode()).hexdigest()})
    result = {
        "chainId": params["chainId"], "block": int(head["number"], 16), "vault": vault, "root": tree["root"],
        "relayer": relayer, "leaves": len(leaves), "alreadyClaimed": sum(flags), "toPush": len(pending),
        "batches": out_batches, "totalClaimedAmount": state["totalClaimedAmount"],
        "status": "complete" if not pending else "pending", "blockHash": head["hash"],
        "treeSha256": k.sha256_file(Path(args.tree)),
        "snapshotSha256": k.sha256_file(Path(args.tree).parent / "snapshot.json"),
        "snapshotBlock": frozen["block"], "snapshotBlockHash": frozen["blockHash"],
        "verificationParams": {"chainId": params["chainId"], "vault": params["vault"]},
        "rehearsal": args.rehearsal, "multicall": k.checksum(ext["multicall3"]),
        "logChunk": getattr(args, "log_chunk", 1000), "payouts": state["paid"],
        "cost": {"baseFeeWei": base_fee, "l2GasTotal": total_gas, "l2FeeWei": total_gas * base_fee,
                 "l1FeeUpperWei": total_l1, "totalWei": total_gas * base_fee + total_l1,
                 "note": "estimateGas per batch at the pinned head; base fee only (no priority fee); "
                         "L1 via GasPriceOracle.getL1FeeUpperBound"},
        "limits": {"gasPerTx": GAS_CAP, "calldataBytesPerTx": CALLDATA_CAP, "headroom": HEADROOM},
    }
    snapshot.check_block(rpc, block, head["hash"], rehearsal=True)
    plan_id = hashlib.sha256(json.dumps(result, sort_keys=True).encode()).hexdigest()
    directory = Path("plans") / plan_id
    result["planDirectory"] = str(directory)
    for batch in out_batches:
        name = batch["file"]
        batch["file"] = str(directory / name)
        write_once(OUT / batch["file"], payloads[name])
    write_once(OUT / directory / "plan.json", json.dumps(result, indent=2) + "\n")
    atomic_json(OUT / "plan.json", result)
    return result


def write_once(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with path.open("x") as file:
            file.write(text)
            file.flush()
            os.fsync(file.fileno())
    except FileExistsError:
        if path.read_text() != text:
            k.fail(f"immutable artifact differs: {path}")


def atomic_json(path: Path, value: dict) -> None:
    import tempfile
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
        json.dump(value, file, indent=2)
        file.write("\n")
        file.flush()
        os.fsync(file.fileno())
        temporary = file.name
    os.replace(temporary, path)


def execute_first(args, rpc: k.Rpc, result: dict, count: int) -> dict:
    k.require_loopback(args.rpc)
    if not args.on_private_anvil:
        k.fail("--execute-first requires --on-private-anvil")
    if "anvil" not in (rpc.call_or_none("web3_clientVersion", []) or "").lower():
        k.fail("--execute-first: not an anvil")
    if rpc.chain_id() != result["chainId"]:
        k.fail("execution chain differs from plan")
    directory = OUT / result["planDirectory"]
    if json.loads((directory / "plan.json").read_text()) != result:
        k.fail("execution plan differs from immutable plan")
    tree_path = Path(args.tree)
    if (k.sha256_file(tree_path) != result["treeSha256"]
            or k.sha256_file(tree_path.parent / "snapshot.json") != result["snapshotSha256"]):
        k.fail("execution tree/snapshot differs from plan")
    frozen = snapshot.verify_snapshot(tree_path, rpc, result["vault"], result["verificationParams"],
                                      rehearsal=result["rehearsal"])
    tree = json.loads(tree_path.read_text())
    journal = OUT / "executions" / directory.name
    outcomes = []

    def state():
        return reconcile(rpc, result["multicall"], result["vault"], tree, frozen, rpc.block(), result["logChunk"])

    def wait_receipt(tx):
        for _ in range(200):
            receipt = rpc.call("eth_getTransactionReceipt", [tx])
            if receipt is not None:
                if (receipt.get("transactionHash", "").lower() != tx.lower()
                        or receipt.get("status") not in ("0x0", "0x1")):
                    k.fail("malformed execution receipt")
                snapshot.check_block(rpc, int(receipt["blockNumber"], 16), receipt["blockHash"], rehearsal=True)
                return receipt
            time.sleep(0.05)
        k.fail("receipt not yet available; keep journal and resume")

    def observe(request, tx=None, receipt=None, unknown=False):
        current = state()
        indices = set(request["batch"]["indices"])
        paid = [p for p in current["paid"].values() if p["index"] in indices]
        actual = sum(p["transactionHash"] == tx for p in paid) if tx else 0
        observation = {"file": request["batch"]["file"], "transactionHash": tx,
                       "actualClaims": None if unknown else actual,
                       "paidInBatch": len(paid), "remainingUnpaid": len(indices) - len(paid),
                       "alreadyPaidBefore": len(request["paidBefore"]),
                       "racedClaims": None if unknown else len(paid) - len(request["paidBefore"]) - actual,
                       "receiptStatus": receipt["status"] if receipt else None,
                       "submissionUnknown": unknown, "block": current["block"], "blockHash": current["blockHash"]}
        outcomes.append(observation)
        progress = {"planDirectory": result["planDirectory"], "block": current["block"],
                    "blockHash": current["blockHash"], "alreadyClaimed": len(current["paid"]),
                    "toPush": len(tree["leaves"]) - len(current["paid"]),
                    "totalClaimedAmount": current["totalClaimedAmount"], "batches": outcomes,
                    "status": "complete" if len(current["paid"]) == len(tree["leaves"]) else "pending"}
        atomic_json(OUT / "progress.json", progress)
        atomic_json(journal / "progress.json", progress)
        return observation, progress

    # A submitted hash survives a crash; an ambiguous send is reconciled, never presumed paid.
    requests = sorted(journal.glob("*/request.json"))
    if len(requests) > 10_000:
        k.fail("execution journal exceeds bounded recovery limit")
    for saved in requests:
        outcome = saved.parent / "outcome.json"
        if outcome.exists():
            outcomes.append(json.loads(outcome.read_text()))
            continue
        request = json.loads(saved.read_text())
        submitted = saved.parent / "submitted.json"
        tx = json.loads(submitted.read_text())["transactionHash"] if submitted.exists() else None
        receipt = wait_receipt(tx) if tx else None
        observed, _ = observe(request, tx, receipt, unknown=not submitted.exists())
        write_once(outcome, json.dumps(observed, indent=2) + "\n")

    progress = None
    rpc.call("anvil_impersonateAccount", [result["relayer"]])
    try:
        rpc.call("anvil_setBalance", [result["relayer"], hex(10**20)])
        for b in result["batches"][:count]:
            path = OUT / b["file"]
            if k.sha256_file(path) != b["sha256"]:
                k.fail("batch calldata differs from immutable plan")
            before = state()
            paid_before = [p["index"] for p in before["paid"].values() if p["index"] in b["indices"]]
            request = {"batch": b, "paidBefore": paid_before, "block": before["block"], "blockHash": before["blockHash"]}
            from uuid import uuid4
            attempt = journal / uuid4().hex
            write_once(attempt / "request.json", json.dumps(request, indent=2) + "\n")
            tx, receipt = None, None
            if len(paid_before) != b["claims"]:
                tx = rpc.call("eth_sendTransaction", [{"from": result["relayer"], "to": b["to"],
                              "data": path.read_text().strip(), "gas": hex(GAS_CAP - 1)}])
                write_once(attempt / "submitted.json", json.dumps({"transactionHash": tx}) + "\n")
                receipt = wait_receipt(tx)
            observed, progress = observe(request, tx, receipt)
            write_once(attempt / "outcome.json", json.dumps(observed, indent=2) + "\n")
            print(f"  {b['file']}: {observed['actualClaims']} actual claims, "
                  f"{observed['remainingUnpaid']} unpaid (not receipt-based)")
            if observed["remainingUnpaid"] or (receipt and receipt["status"] != "0x1"):
                k.fail("push batch has unpaid/reverted claims; progress saved, replan before retry")
    finally:
        rpc.call("anvil_stopImpersonatingAccount", [result["relayer"]])
    return progress or {"batches": outcomes}


def main() -> None:
    ap = argparse.ArgumentParser(description="Launch kit push plan: idempotent Multicall3 claim batches.")
    ap.add_argument("--tree", required=True)
    ap.add_argument("--rpc")
    ap.add_argument("--params")
    ap.add_argument("--rehearsal", action="store_true")
    ap.add_argument("--deployment", default=str(k.OUTPUT / "deploy" / "deployment.json"))
    ap.add_argument("--execute-first", type=int, default=0)
    ap.add_argument("--resume-plan", type=Path, help="resume an immutable plans/<id>/plan.json and recover its journal")
    ap.add_argument("--on-private-anvil", action="store_true")
    ap.add_argument("--log-chunk", type=int, default=1000, help="bounded payout-event page size in blocks")
    args = ap.parse_args()
    params = k.load_phase_params(args.params, rehearsal=args.rehearsal)
    args.rpc = k.rpc_url(args.rpc)
    rpc = k.Rpc(args.rpc)
    if rpc.chain_id() != params["chainId"]:
        k.fail(f"RPC chainId {rpc.chain_id()} != params.chainId {params['chainId']}")
    if args.resume_plan:
        result = json.loads(args.resume_plan.read_text())
        if (not args.execute_first or result["rehearsal"] != args.rehearsal
                or result["verificationParams"] != {"chainId": params["chainId"], "vault": params["vault"]}):
            k.fail("resume requires execution and the original mode/vault parameters")
    else:
        result = plan(args, params, rpc)
    _print(result)
    if args.execute_first:
        execute_first(args, rpc, result, args.execute_first)
        print("replanning after the executed batches:")
        _print(plan(args, params, rpc))


def _print(r: dict) -> None:
    c = r["cost"]
    biggest = max(r["batches"], key=lambda b: b["estimatedGas"], default=None)
    print(f"push plan at block {r['block']}: {r['leaves']} leaves, {r['alreadyClaimed']} already claimed, "
          f"{r['toPush']} to push in {len(r['batches'])} batches")
    if biggest:
        print(f"  largest batch: {biggest['estimatedGas']:,} gas (cap {GAS_CAP:,}), "
              f"{max(b['calldataBytes'] for b in r['batches']):,} bytes (cap {CALLDATA_CAP:,})")
    print(f"  cost at base fee {c['baseFeeWei']} wei: L2 {c['l2GasTotal']:,} gas = {c['l2FeeWei']} wei, "
          f"L1 upper {c['l1FeeUpperWei']} wei, total {c['totalWei']} wei")
    print(f"  wrote {OUT.relative_to(k.PROJECT)}/plan.json + {len(r['batches'])} batch files")


if __name__ == "__main__":
    main()
