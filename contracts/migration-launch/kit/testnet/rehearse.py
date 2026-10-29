#!/usr/bin/env python3
"""Own a fresh loopback-only Anvil fork, exercise the unsigned CLI, then terminate it.

No private key input or public send path exists. Deterministic, worthless actor addresses
are impersonated only after verifying Anvil's real Base Sepolia origin and dependencies.
"""
import argparse
import copy
import json
from pathlib import Path
import socket
import subprocess
import sys
import time
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prepare as p


def actor(name):
    return p.k.checksum("0x" + p.k.keccak(("SUR-768 local-only actor: " + name).encode())[12:].hex())


def fixture(now):
    return {"schema": 1, "mode": "testnet", "chainId": p.CHAIN, "validUntil": now + 7200,
            "deployer": actor("deployer"),
            "governance": {"owners": [actor("owner-1"), actor("owner-2"), actor("owner-3")],
                           "threshold": 2, "saltNonce": now},
            "token": {"name": "TEST ONLY Surplus V2", "symbol": "TEST-V2", "capWei": "1000000000000000000000000"},
            "vault": {"depositDeadline": now + 900, "commitDeadline": now + 1800, "executionWindowSeconds": 900,
                      "claimPeriodSeconds": 0, "rateBps": 10000, "proRata": True}}


def guard(url, origin, canonical_url):
    parsed = urlsplit(url)
    p.require(parsed.scheme == "http" and parsed.hostname == "127.0.0.1" and parsed.port
              and not parsed.username and not parsed.password and parsed.path in ("", "/")
              and not parsed.query and not parsed.fragment, "writes require owned numeric loopback Anvil")
    local, canonical = p.ReadRpc(url), p.ReadRpc(canonical_url)
    p.require(local.chain_id() == canonical.chain_id() == p.CHAIN, "local/canonical chain must be 84532")
    p.require("anvil" in local.call("web3_clientVersion", []).lower()
              and "anvil" not in canonical.call("web3_clientVersion", []).lower(), "not real canonical Sepolia + Anvil")
    pin = origin["block"]
    p.require(p.block_id(local.block(pin["number"])) == pin == p.block_id(canonical.block(pin["number"])), "fork block origin mismatch")
    info = local.call("anvil_nodeInfo", [])
    p.require(info["forkConfig"]["forkBlockNumber"] == pin["number"], "not a fresh pinned fork")
    p.require(info["forkConfig"]["forkUrl"] == canonical_url, "fork upstream differs from verified canonical RPC")
    for dep in p.dependencies()["contracts"].values():
        p.require(p.safe.code_hash(local, dep["address"]) == dep["runtimeCodeHash"], "local dependency hash mismatch")
    return {"block": pin, "chainId": p.CHAIN, "dependenciesVerified": True, "forkOriginVerified": True}


class LocalRpc(p.ReadRpc):
    ALLOWED = p.ReadRpc.ALLOWED | {"eth_estimateGas", "eth_sendTransaction", "anvil_setBalance",
                                  "anvil_impersonateAccount", "anvil_stopImpersonatingAccount",
                                  "evm_snapshot", "evm_revert", "evm_setNextBlockTimestamp", "evm_mine"}

    def __init__(self, url, origin, canonical_url, out):
        self.evidence = guard(url, origin, canonical_url)
        super().__init__(url)
        self.out = out
        self.branch = "deployment"
        self.sequence = 0

    def _request(self, method, params):
        if method not in p.ReadRpc.ALLOWED:
            identity = super()._request("eth_chainId", [])
            p.require(int(identity["result"], 16) == p.CHAIN, "local chain changed; writes refused")
        result = super()._request(method, params)
        if method == "eth_getTransactionReceipt" and result.get("result"):
            self.sequence += 1
            p.save(self.out / self.branch / "receipts" / f"{self.sequence:04}.json", result["result"])
        return result


def cli(out, command, *args, failure=False):
    argv = [sys.executable, "-B", str(p.HERE / "prepare.py"), command, *map(str, args)]
    run = subprocess.run(argv, cwd=p.k.PROJECT, capture_output=True, text=True, timeout=240)
    log = "$ " + p.k.scrub(" ".join(argv)) + "\n" + p.k.scrub(run.stdout + run.stderr)
    with (out / "cli.log").open("a") as stream:
        stream.write(log + f"exit={run.returncode}\n")
    p.require((run.returncode != 0) if failure else (run.returncode == 0), log)
    return run


def rejected(rpc, sender, target, data, signature, out, name):
    result = rpc._request("eth_call", [{"from": sender, "to": target, "data": "0x" + data.hex()}, "latest"])
    reason = result.get("error", {}).get("data", "")
    p.require(reason.startswith("0x" + p.k.selector(signature).hex()), name + ": wrong/missing revert")
    p.save(out / rpc.branch / (name + ".json"), result)


def send(rpc, sender, target, data):
    return p.safe.send(rpc, sender, target, data)


def warp(rpc, timestamp):
    rpc.call("evm_setNextBlockTimestamp", [timestamp])
    rpc.call("evm_mine", [])
    p.require(p.block_id(rpc.block())["timestamp"] == timestamp, "time advance failed")


def execute(rpc, plan, params, packet, out):
    tx = dict(packet["safeTransaction"], data=bytes.fromhex(packet["safeTransaction"]["data"][2:]))
    hash_ = bytes.fromhex(packet["safeTxHash"][2:])
    p.require(p.safe.safe_tx_hash(rpc, p.CHAIN, plan["addresses"]["safe"], tx) == hash_, "packet hash differs from Safe")
    result = p.safe.execute(rpc, plan["addresses"]["safe"], params["governance"], tx, hash_)
    p.save(out / rpc.branch / (packet["action"] + "-executed.json"), result)


def lifecycle(out, url, canonical, params, origin):
    rpc = LocalRpc(url, origin, canonical, out)
    p.save(out / "origin-verified.json", rpc.evidence)
    params_path, plan_path = out / "params.json", out / "plan.json"
    cli(out, "validate", "--params", params_path)
    cli(out, "plan", "--params", params_path, "--preflight", out / "preflight.json", "--out", plan_path)
    cli(out, "simulate", "--params", params_path, "--plan", plan_path, "--rpc", url, "--out", out / "simulation.json")
    cli(out, "explorer", "--params", params_path, "--plan", plan_path, "--out", out / "explorer")
    cli(out, "config-plan", "--params", params_path, "--plan", plan_path, "--rpc", canonical, "--out", out / "public-config-disabled.json")
    cli(out, "validate", "--params", p.HERE / "params.json", failure=True)
    plan = json.loads(plan_path.read_text())
    a = plan["addresses"]
    for tx in plan["transactions"]:
        send(rpc, params["deployer"], tx["to"], bytes.fromhex(tx["data"][2:]))
    deployed = p.block_id(rpc.block())["number"]
    common = ["--params", params_path, "--plan", plan_path, "--rpc", url, "--local"]
    cli(out, "verify", *common, "--out", out / "verified.json")
    expected = json.loads((out / "simulation.json").read_text())
    for label in ("runtime", "quorum"):
        bad_params, bad_expected = copy.deepcopy(params), copy.deepcopy(expected)
        if label == "runtime":
            bad_expected["runtimeCode"]["vault"] += "00"
        else:
            bad_params["governance"]["threshold"] = 3
        try:
            p.readback(plan, bad_params, p.ReadRpc(url), bad_expected, True)
        except ValueError as error:
            p.require(label in str(error), "unexpected readback failure")
            p.save(out / ("rejected-" + label + ".json"), {"rejected": str(error)})
        else:
            raise ValueError("tampered readback accepted")
    bad = copy.deepcopy(plan)
    bad["addresses"]["vault"] = actor("not-the-vault")
    p.save(out / "tampered-plan.json", bad)
    cli(out, "verify", "--params", params_path, "--plan", out / "tampered-plan.json", "--rpc", url,
        "--local", "--out", out / "invalid-verify.json", failure=True)
    cli(out, "config", *common, "--web-rpc", url, "--out", out / "web-config.json")
    cli(out, "config", *common, "--web-rpc", "https://sepolia.base.org", "--out", out / "invalid-config.json", failure=True)
    alice, bob, relayer = actor("alice"), actor("bob"), actor("relayer")
    for who, amount in ((alice, 100 * 10**18), (bob, 150 * 10**18)):
        send(rpc, who, a["v1"], p.safe.encode("faucet(address,uint256)", p.k.addr_word(who), p.k.word(amount)))
        send(rpc, who, a["v1"], p.safe.encode("approve(address,uint256)", p.k.addr_word(a["vault"]), p.k.word(amount)))
        send(rpc, who, a["vault"], p.safe.encode("deposit(uint256)", p.k.word(amount)))
        p.require(p.safe.uint(rpc, a["vault"], "credited(address)", p.k.addr_word(who)) == amount, "deposit readback")
    send(rpc, alice, a["vault"], p.safe.encode("withdrawV1(uint256)", p.k.word(20 * 10**18)))
    p.require(p.safe.uint(rpc, a["vault"], "withdrawn(address)", p.k.addr_word(alice)) == 20 * 10**18, "withdrawal readback")
    checkpoint = rpc.call("evm_snapshot", [])

    def packet(action, *args, failure=False):
        target = out / rpc.branch / (action + ("-rejected" if failure else "") + ".json")
        cli(out, "packet", *common, "--action", action, *args, "--out", target, failure=failure)
        return {} if failure else json.loads(target.read_text())

    def refunds():
        for who, initial in ((alice, 100), (bob, 150)):
            target = out / rpc.branch / (who + "-refund.json")
            cli(out, "packet", *common, "--action", "refund", "--account", who, "--out", target)
            call = json.loads(target.read_text())["transaction"]
            send(rpc, relayer, call["to"], bytes.fromhex(call["data"][2:]))
            p.require(p.safe.balance(rpc, a["v1"], who) == initial * 10**18, "refund conserves V1")
            p.require(p.safe.uint(rpc, a["vault"], "availableToWithdraw(address)", p.k.addr_word(who)) == 0, "refund clears credit")
        rejected(rpc, relayer, a["vault"], p.safe.encode("refund(address)", p.k.addr_word(alice)),
                 "NothingToWithdraw()", out, "double-refund-rejected")

    rpc.branch = "cancellation"
    cancellation = packet("cancel", "--safe-nonce", 0)
    tx = dict(cancellation["safeTransaction"], data=bytes.fromhex(cancellation["safeTransaction"]["data"][2:]))
    one = p.k.addr_word(params["governance"]["owners"][0]) + p.k.word(0) + b"\x01"
    result = rpc._request("eth_call", [{"from": relayer, "to": a["safe"], "data": "0x" + p.safe.exec_data(tx, one).hex()}, "latest"])
    p.require(result.get("error", {}).get("data") == "0x" + p.safe.cast_calldata("Error(string)", "GS020").hex(), "real Safe failed to reject below quorum")
    p.save(out / rpc.branch / "below-quorum-GS020.json", result)
    execute(rpc, plan, params, cancellation, out)
    p.require(p.safe.uint(rpc, a["vault"], "phase()") == 2, "Safe cancellation readback")
    warp(rpc, params["validUntil"] + 1)
    refunds()
    p.require(rpc.call("evm_revert", [checkpoint]), "restore failed")
    checkpoint = rpc.call("evm_snapshot", [])

    rpc.branch = "commit-timeout"
    packet("expire-commit", failure=True)
    warp(rpc, params["validUntil"] + 1)
    timeout = packet("expire-commit")["transaction"]
    send(rpc, relayer, timeout["to"], bytes.fromhex(timeout["data"][2:]))
    refunds()
    p.require(rpc.call("evm_revert", [checkpoint]), "restore failed")
    checkpoint = rpc.call("evm_snapshot", [])

    for branch in ("execution-timeout", "success"):
        rpc.branch = branch
        warp(rpc, params["vault"]["depositDeadline"] + 1)
        frozen = p.block_id(rpc.block())["number"]
        tree_dir = out / branch / "snapshot"
        cli(out, "snapshot", *common, "--block", frozen, "--from-block", deployed, "--out", tree_dir)
        tree = tree_dir / "tree.json"
        if branch == "success":
            original_tree = json.loads(tree.read_text())
            original_snapshot = json.loads((tree_dir / "snapshot.json").read_text())
            for change in ("balanced-wrong-ledger", "mixed-plan", "wrong-block"):
                bad_dir = out / branch / change
                bad_tree, bad_snapshot = copy.deepcopy(original_tree), copy.deepcopy(original_snapshot)
                if change == "balanced-wrong-ledger":
                    rows = [(leaf["account"], int(leaf["amount"]) + (1 if i == 0 else -1))
                            for i, leaf in enumerate(bad_tree["leaves"])]
                    bad_tree = p.build_tree(rows)
                    bad_snapshot["root"] = bad_tree["root"]
                elif change == "mixed-plan":
                    bad_snapshot["planHash"] = "0" * 64
                else:
                    bad_snapshot["blockHash"] = "0x" + "11" * 32
                p.save(bad_dir / "tree.json", bad_tree)
                bad_snapshot["sha256"]["tree.json"] = p.k.sha256_file(bad_dir / "tree.json")
                p.save(bad_dir / "snapshot.json", bad_snapshot)
                cli(out, "packet", *common, "--action", "commit-root", "--safe-nonce", 0,
                    "--tree", bad_dir / "tree.json", "--out", bad_dir / "must-not-exist.json", failure=True)
        commitment = packet("commit-root", "--safe-nonce", 0, "--tree", tree)
        cli(out, "check-packet", *common, "--packet", out / branch / "commit-root.json", "--tree", tree,
            "--out", out / branch / "commit-checked.json")
        rejected(rpc, params["deployer"], a["vault"], bytes.fromhex(commitment["calls"][0]["data"][2:]), "NotOwner()", out, "EOA-commit-rejected")
        tampered = copy.deepcopy(commitment)
        tampered["safeTransaction"]["nonce"] = 9
        tampered["packetHash"] = p.digest({key: value for key, value in tampered.items() if key != "packetHash"})
        p.save(out / branch / "tampered-packet.json", tampered)
        cli(out, "check-packet", *common, "--packet", out / branch / "tampered-packet.json", "--tree", tree,
            "--out", out / branch / "must-not-check.json", failure=True)
        execute(rpc, plan, params, commitment, out)
        cli(out, "check-packet", *common, "--packet", out / branch / "commit-root.json", "--tree", tree,
            "--out", out / branch / "stale-packet.json", failure=True)
        p.require(p.safe.view(rpc, a["vault"], "root()").hex() == json.loads(tree.read_text())["root"][2:], "root readback")
        if branch == "execution-timeout":
            warp(rpc, params["validUntil"] + 1)
            packet("activate", "--safe-nonce", 1, "--tree", tree, failure=True)
            timeout = packet("expire-execution")["transaction"]
            send(rpc, relayer, timeout["to"], bytes.fromhex(timeout["data"][2:]))
            refunds()
            p.require(rpc.call("evm_revert", [checkpoint]), "restore failed")
        else:
            packet("activate", "--safe-nonce", 9, "--tree", tree, failure=True)
            activation = packet("activate", "--safe-nonce", 1, "--tree", tree)
            cli(out, "check-packet", *common, "--packet", out / branch / "activate.json", "--tree", tree,
                "--out", out / branch / "activation-checked.json")
            execute(rpc, plan, params, activation, out)
            p.require(p.safe.uint(rpc, a["vault"], "claimsActive()") == 1, "Safe activation readback")
            p.require(p.safe.balance(rpc, a["token"], a["vault"]) == 230 * 10**18, "full claim backing")
            send(rpc, alice, a["vault"], p.safe.encode("claimProRata()"))
            leaf = next(x for x in json.loads(tree.read_text())["leaves"] if x["account"].lower() == bob.lower())
            claim = p.safe.cast_calldata("claim(uint256,address,uint256,bytes32[])", str(leaf["index"]), bob,
                                         leaf["amount"], "[" + ",".join(leaf["proof"]) + "]")
            send(rpc, relayer, a["vault"], claim)
            p.require(p.safe.balance(rpc, a["token"], alice) == 80 * 10**18 and p.safe.balance(rpc, a["token"], bob) == 150 * 10**18, "beneficiaries paid 1:1")
            p.require(p.safe.balance(rpc, a["token"], relayer) == 0, "relayer cannot steal claim")
            rejected(rpc, alice, a["vault"], p.safe.encode("claimProRata()"), "AlreadyClaimedAccount(address)", out, "double-formula-rejected")
            rejected(rpc, relayer, a["vault"], claim, "AlreadyClaimed(uint256)", out, "double-merkle-rejected")
            packet("refund", "--account", alice, failure=True)
            packet("cancel", "--safe-nonce", 2, failure=True)
            warp(rpc, params["validUntil"] + 1)
            old, new = params["governance"]["owners"][0], actor("rotated-owner")
            rotation = packet("rotate", "--safe-nonce", 2, "--old-owner", old, "--new-owner", new)
            cli(out, "check-packet", *common, "--packet", out / branch / "rotate.json", "--out", out / branch / "rotation-checked.json")
            execute(rpc, plan, params, rotation, out)
            p.require(p.safe.uint(rpc, a["safe"], "isOwner(address)", p.k.addr_word(old)) == 0, "old owner not removed")
            p.require(p.safe.uint(rpc, a["safe"], "isOwner(address)", p.k.addr_word(new)) == 1, "new owner not installed")
            expected = json.loads((out / "simulation.json").read_text())
            g = {"owners": rotation["rotation"]["ownersAfter"], "threshold": 2}
            p.save(out / "rotated-readback.json", p.readback(plan, params, p.ReadRpc(url), expected, True, g))
            cli(out, "verify-rotation", *common, "--packet", out / branch / "rotate.json", "--out", out / "rotation-verified.json")
            probe = p.k.keccak(b"SUR-768 local rotation liveness, no execution")
            data = p.safe.encode("approveHash(bytes32)", probe)
            result = rpc._request("eth_call", [{"from": old, "to": a["safe"], "data": "0x" + data.hex()}, "latest"])
            p.require(result.get("error", {}).get("data") == "0x" + p.safe.cast_calldata("Error(string)", "GS030").hex(), "removed owner still authorizes")
            p.save(out / branch / "old-owner-GS030.json", result)
            send(rpc, new, a["safe"], data)
            p.require(p.safe.uint(rpc, a["safe"], "approvedHashes(address,bytes32)", p.k.addr_word(new), probe) == 1, "new signer unable to authorize")
    p.save(out / "result.json", {"status": "PASS", "scope": "private-loopback-fork-only", "chainId": p.CHAIN,
                                "planHash": plan["planHash"], "origin": origin["block"], "publicWrites": False,
                                "checks": ["official Safe quorum rejection GS020", "deposit/withdraw", "cancel/refund",
                                           "commit-timeout/refund", "execution-timeout/refund", "Safe commit/activate",
                                           "1:1 formula and relayed Merkle claims", "double-claim rejection", "signer rotation"]})


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--canonical-rpc", default="https://sepolia.base.org")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    parsed = urlsplit(args.canonical_rpc)
    p.require(parsed.scheme == "https" and not parsed.username and not parsed.password, "canonical RPC must be public HTTPS")
    out = args.out.resolve()
    p.require(not out.exists(), "choose a new empty evidence directory")
    params = fixture(max(int(time.time()), p.block_id(p.ReadRpc(args.canonical_rpc).block())["timestamp"]))
    p.save(out / "params.json", params)
    cli(out, "preflight", "--params", out / "params.json", "--rpc", args.canonical_rpc, "--out", out / "preflight.json")
    origin = json.loads((out / "preflight.json").read_text())
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    url = f"http://127.0.0.1:{port}"
    with (out / "anvil.log").open("w") as log:
        process = subprocess.Popen(["anvil", "--fork-url", args.canonical_rpc, "--fork-block-number", str(origin["block"]["number"]),
                                    "--chain-id", str(p.CHAIN), "--accounts", "0", "--host", "127.0.0.1", "--port", str(port), "--silent"],
                                   stdout=log, stderr=log)
        try:
            for _ in range(100):
                p.require(process.poll() is None, "Anvil exited during startup")
                try:
                    if p.ReadRpc(url).chain_id() == p.CHAIN:
                        break
                except ValueError:
                    time.sleep(0.1)
            else:
                raise ValueError("Anvil readiness timeout")
            lifecycle(out, url, args.canonical_rpc, params, origin)
        finally:
            process.terminate()
            process.wait(timeout=15)
    print("PASS: isolated Base Sepolia rehearsal; Anvil stopped; no public transaction sent")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        sys.exit("REHEARSAL STOP: " + p.k.scrub(str(error)))
