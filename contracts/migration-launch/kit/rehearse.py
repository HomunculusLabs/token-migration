#!/usr/bin/env python3.14
"""REHEARSAL ONLY: drives a private anvil through the parts of launch that people, not the kit, do: the
deployer's transactions, every holder's deposit, and time passing. Everything else in a rehearsal goes
through the kit's own phases (deploy_plan, snapshot, safe_txs, push_plan), exactly as on launch day.

    python3.14 kit/rehearse.py deploy  --rpc http://127.0.0.1:PORT
    python3.14 kit/rehearse.py deposit --rpc http://127.0.0.1:PORT --cohort kit/output/cohort/cohort.json
    python3.14 kit/rehearse.py close   --rpc http://127.0.0.1:PORT

It refuses anything but a loopback anvil on chain 8453. It sends transactions as unlocked (impersonated)
accounts, which only an anvil fork allows, and funds senders with gas ETH through anvil_setBalance. ETH
balances play no part in the migration, and v1 balances are never touched.
"""
import argparse
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kitlib as k  # noqa: E402

DEPLOY = k.OUTPUT / "deploy"
GAS_ETH = hex(10**20)


def private_anvil(url: str) -> k.Rpc:
    k.require_loopback(url)
    rpc = k.Rpc(url)
    if rpc.chain_id() != 8453:
        k.fail("not a Base fork")
    version = rpc.call_or_none("web3_clientVersion", []) or ""
    if "anvil" not in version.lower():
        k.fail(f"not an anvil ({version})")
    rpc.call("anvil_autoImpersonateAccount", [True])
    return rpc


def send(rpc: k.Rpc, sender: str, to: str, data: bytes, gas: int = 15_000_000) -> dict:
    tx = rpc.call("eth_sendTransaction", [{"from": sender, "to": to, "data": "0x" + data.hex(), "gas": hex(gas)}])
    receipt = None
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        receipt = rpc.call("eth_getTransactionReceipt", [tx])
        if receipt is not None:
            break
        time.sleep(0.05)
    if receipt is None:
        k.fail(f"transaction not yet confirmed: {tx}; inspect its receipt before resuming, do not blindly resubmit")
    if receipt["status"] != "0x1":
        k.fail(f"transaction from {sender} to {to} failed: {tx}")
    return receipt


def deploy(rpc: k.Rpc) -> None:
    resolved = json.loads((DEPLOY / "resolved.json").read_text())
    plan = json.loads((DEPLOY / "plan.json").read_text())
    deployer = resolved["operators"]["deployer"]
    rpc.call("anvil_setBalance", [deployer, GAS_ETH])
    if rpc.call("eth_getCode", [plan["safe"], "latest"]) in ("0x", "0x0"):
        data = (k.selector("createProxyWithNonce(address,bytes,uint256)") + k.addr_word(resolved["safe141"]["singleton"])
                + k.word(96) + k.word(resolved["governance"]["saltNonce"]))
        initializer = bytes.fromhex(plan["safeInitializer"][2:])
        data += k.word(len(initializer)) + initializer + b"\x00" * (-len(initializer) % 32)
        send(rpc, deployer, resolved["safe141"]["proxyFactory"], data)
    steps = (("tokenImplementation", resolved["salts"]["tokenImplementation"], "tokenImplementationInitCode"),
             ("token", resolved["salts"]["tokenProxy"], "tokenProxyInitCode"),
             ("vault", resolved["salts"]["vault"], "vaultInitCode"),
             ("settler", resolved["salts"]["settler"], "settlerInitCode"),
             ("hook", plan["hookSalt"], "hookInitCode"))
    for name, salt, init_key in steps:
        if rpc.call("eth_getCode", [plan[name], "latest"]) in ("0x", "0x0"):
            send(rpc, deployer, resolved["create2Deployer"], bytes.fromhex(salt[2:] + plan[init_key][2:]))
        if rpc.call("eth_getCode", [plan[name], "latest"]) in ("0x", "0x0"):
            k.fail(f"{name}: nothing at the planned address {plan[name]}")
        print(f"{name:20} {plan[name]}")
    print(f"{'safe':20} {plan['safe']}")
    print(f"deployed at block {int(rpc.block()['number'], 16)}")


def deposit(rpc: k.Rpc, cohort_path: Path) -> None:
    plan = json.loads((DEPLOY / "plan.json").read_text())
    resolved = json.loads((DEPLOY / "resolved.json").read_text())
    vault, v1 = plan["vault"], resolved["v1"]
    cohort = json.loads(cohort_path.read_text())
    holders = list(zip(cohort["accounts"], (int(a) for a in cohort["amounts"])))
    pending = rpc.call("txpool_status", [])
    if int(pending["pending"], 16) or int(pending["queued"], 16):
        k.fail("unconfirmed transactions remain; inspect their receipts before resuming deposits")
    if int(rpc.eth_call(vault, "0x" + k.selector("phase()").hex()), 16) != 0:
        k.fail("deposit replay requires an open vault")
    start = time.time()

    def fund(entry):
        rpc_local = k.Rpc(rpc._url)  # one connection per worker
        rpc_local.call("anvil_setBalance", [entry[0], GAS_ETH])

    with ThreadPoolExecutor(16) as pool:
        list(pool.map(fund, holders))
    approve = k.selector("approve(address,uint256)") + k.addr_word(vault)
    total, gas, skipped = 0, 0, 0
    for i, (holder, amount) in enumerate(holders):
        balance = int(rpc.eth_call(v1, "0x" + (k.selector("balanceOf(address)") + k.addr_word(holder)).hex()), 16)
        credited = int(rpc.eth_call(vault, "0x" + (k.selector("credited(address)") + k.addr_word(holder)).hex()), 16)
        withdrawn = int(rpc.eth_call(vault, "0x" + (k.selector("withdrawn(address)") + k.addr_word(holder)).hex()), 16)
        if withdrawn != 0 or credited not in (0, amount):
            k.fail(f"{holder}: ledger differs from an untouched or fully deposited cohort entry")
        if credited == amount:
            if balance != 0:
                k.fail(f"{holder}: already deposited but v1 balance is not zero; inspect the changed state")
            skipped += 1
        else:
            if balance != amount:
                k.fail(f"{holder}: live v1 balance {balance} != cohort amount {amount}")
            gas += int(send(rpc, holder, v1, approve + k.word(amount), 200_000)["gasUsed"], 16)
            gas += int(send(rpc, holder, vault, k.selector("deposit(uint256)") + k.word(amount), 300_000)["gasUsed"], 16)
        total += amount
        if (i + 1) % 500 == 0:
            print(f"  {i + 1}/{len(holders)} deposited ({time.time() - start:.0f}s)", flush=True)
    on_chain = int(rpc.eth_call(vault, "0x" + k.selector("totalDepositedV1()").hex()), 16)
    if on_chain != total or total != int(cohort["eligibleTotal"]):
        k.fail(f"vault totalDepositedV1 {on_chain} != Σ cohort {total}")
    print(f"{len(holders)} holders deposited {total} v1 (= cohort eligibleTotal); "
          f"{skipped} already deposited; newly sent approve + deposit gas {gas}; {time.time() - start:.0f}s")
    print(f"last deposit block {int(rpc.block()['number'], 16)}")


def close(rpc: k.Rpc) -> None:
    plan = json.loads((DEPLOY / "plan.json").read_text())
    deadline = int(rpc.eth_call(plan["vault"], "0x" + k.selector("DEPOSIT_DEADLINE()").hex()), 16)
    now = int(rpc.block()["timestamp"], 16)
    if now <= deadline:
        rpc.call("evm_setNextBlockTimestamp", [hex(deadline + 1)])
    rpc.call("evm_mine", [])
    head = rpc.block()
    print(f"deposit window closed: block {int(head['number'], 16)} t={int(head['timestamp'], 16)} > deadline {deadline}")


def main() -> None:
    ap = argparse.ArgumentParser(description="Rehearsal-only anvil driver (deploy, deposit, close).")
    ap.add_argument("step", choices=("deploy", "deposit", "close"))
    ap.add_argument("--rpc", required=True)
    ap.add_argument("--cohort", type=Path)
    args = ap.parse_args()
    rpc = private_anvil(args.rpc)
    if args.step == "deploy":
        deploy(rpc)
    elif args.step == "deposit":
        if not args.cohort:
            k.fail("deposit needs --cohort")
        deposit(rpc, args.cohort)
    else:
        close(rpc)


if __name__ == "__main__":
    main()
