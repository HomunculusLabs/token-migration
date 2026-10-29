#!/usr/bin/env python3.14
"""Launch kit, phase "safe-txs": the launch's two Safe transactions, each run through the real Safe on a
private anvil fork before anyone signs.

    python3.14 kit/safe_txs.py commit-root  --tree <tree.json> --deployment <deployment.json> --safe-nonce K
                                            --rpc <private anvil> [--params kit/params.json | --rehearsal]
                                            [--execute-on-private-fork]
    python3.14 kit/safe_txs.py launch-batch --deployment <deployment.json> --safe-nonce K
                                            --rpc <private anvil> [--params kit/params.json | --rehearsal]
                                            [--execute-on-private-fork]

deployment.json is the deploy-plan phase's {"safe", "token", "vault", "settler", "hook", "v2"}; the kit
checks on chain that those contracts are wired to each other and to params before it builds anything.

commit-root: vault.commitRoot(root, total) from the snapshot's tree.json, a plain CALL from the Safe. The
root, total and every entitlement are checked against the mandatory adjacent snapshot and chain ledger.
Live signing requires --canonical-rpc <read-only Base archive RPC> for both ledger reads and finalized block
identity; private Anvil finality is never accepted. --rehearsal explicitly labels private-chain evidence.

launch-batch: ONE Safe transaction, a DELEGATECALL to the launch contract's launch() (src/MigrationLaunch.sol).
The contract holds every number as an immutable and runs five steps as the Safe:
    1. v2.mint(vault, backing)                        backing = vault.totalClaimable()
    2. vault.activateClaims()
    3. vault.withdrawV1ForSettlement(settler, v1In)   v1In = the vault's net ledger
    4. v2.mint(settler, budget)
    5. settler.settle(params)
then checks the result and that the Safe's settings did not change. backing and v1In are read from the vault,
never from a file. The seed is read from the fork before anything runs (kit/seed.py): the opening tick, and the
v2 ranges that copy the v1 the old pool holds above its price. The kit deploys each launch contract through the
pinned CREATE2 deployer (external.create2Deployer), so its address follows from its code and its numbers.
Simulate, then sign: a launch contract with no floor and the whole remaining cap as budget runs first; then
minWethOut = raised × sale.minWethOutBps / 10 000 and budget = v2 used + sale.v2BudgetExtraWei (0.995 and
10 wei: the v2 side is fixed by the signed ranges, not by the sale, so it needs no drift margin), and the
SIGNED launch contract runs from the same pre-state. It must succeed and pass every launch check.
On the real chain, send launch-batch.deploy.json BEFORE the Safe transaction executes: a Safe DELEGATECALL to
an address with no code succeeds and does nothing.

Every simulation is a real transaction on the private anvil: the first `threshold` owners by address
(impersonated) each call approveHash, then a non-owner calls execTransaction with approved-hash signatures
(v = 1) sorted by owner. The anvil is reverted afterwards unless --execute-on-private-fork is given, which
a rehearsal uses so that the next phase starts from the executed state. Nothing is signed with a key and
nothing reaches a real chain. --rpc must be an anvil started for this run: it receives transactions.

Every safeTxHash is computed twice and the two must agree: EIP-712 in pure Python (Safe 1.4.1: domain
{chainId, verifyingContract}, the SafeTx struct) and the Safe's own getTransactionHash on the fork.

Outputs in kit/output/safe-txs/, for <name> = commitRoot and launch-batch:
    commitRoot.json          Safe Transaction Builder import (createdAt 0, empty checksum: reruns are byte-identical)
    launch-batch.deploy.json the launch contract's deployment: the one transaction to send before the Safe executes
                             (no Transaction Builder file: the Builder cannot make a DELEGATECALL)
    <name>.calldata.txt      the exact execTransaction parameters: to, value, operation, gas fields, nonce, data
    <name>.safeTxHash.txt    the hash each signer's device must show
    <name>.safe-tx.json      the same, plus the calls the Safe makes, both hashes and every check that passed
    simulation.json          (launch-batch) the unconstrained run, the signed limits and the signed run
"""
import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kitlib as k  # noqa: E402
import seed as seeds  # noqa: E402
import snapshot as snapshots  # noqa: E402

OUT = k.OUTPUT / "safe-txs"
ZERO = "0x" + "00" * 20
CALL, DELEGATECALL = 0, 1
TX_BUILDER_VERSION = "1.16.5"
# Safe 1.4.1 (Safe.sol): the EIP-712 type hashes, checked against their type strings at start.
DOMAIN_TYPEHASH = bytes.fromhex("47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218")
SAFE_TX_TYPEHASH = bytes.fromhex("bb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8")
DOMAIN_TYPE = b"EIP712Domain(uint256 chainId,address verifyingContract)"
SAFE_TX_TYPE = (b"SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,"
                b"uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)")
EXEC_SIG = "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)"
HASH_SIG = "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)"
EXECUTION_SUCCESS = "0x" + k.keccak(b"ExecutionSuccess(bytes32,uint256)").hex()
POOL_KEY = "(address,address,uint24,int24,address)"
V2_RANGE = "(int24,int24,uint128)"
SETTLE_PARAMS = f"({POOL_KEY},uint256,uint256,uint160,{POOL_KEY},int24,{V2_RANGE}[],uint256)"
SETTLE_SIG = f"settle({SETTLE_PARAMS})"
# The launch contract: its forge artifact, the CREATE2 salt the kit deploys it with (the deploy plan's "surp" salt
# family, next after the settler's), and its constructor (Config, Params).
LAUNCH_ARTIFACT = k.PROJECT / "out" / "MigrationLaunch.sol" / "MigrationLaunch.json"
LAUNCH_SALT = bytes.fromhex("7375727000000000000000000000000000000000000000000000000000000005")
LAUNCH_CONSTRUCTOR = f"constructor((address,address,address,address,uint256,uint256),{SETTLE_PARAMS})"
# Safe 1.4.1: the head of the module list, and the guard and fallback-handler storage slots.
SENTINEL = "0x" + "00" * 19 + "01"
GUARD_SLOT = "0x" + k.keccak(b"guard_manager.guard.address").hex()
FALLBACK_HANDLER_SLOT = "0x" + k.keccak(b"fallback_manager.handler.address").hex()
RECEIPT = ("wethRaised", "wethSeeded", "v2Seeded", "firstPositionId", "positionCount", "wethLiquidity")
# Sends execTransaction in the simulations. Not an owner, so execution rests on the owners' approvals alone.
EXECUTOR = k.checksum("0x" + k.keccak(b"surplus launch kit: simulation executor")[12:].hex())
POOLS_SLOT = 6  # v4 PoolManager: mapping(PoolId => Pool.State) _pools; slot0 is the struct's first word
PHASE_COMMITTED = 1


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Launch kit safe-txs: commitRoot and the atomic launch batch.")
    ap.add_argument("tx", choices=("commit-root", "launch-batch"))
    ap.add_argument("--deployment", type=Path, required=True)
    ap.add_argument("--safe-nonce", type=int, required=True)
    ap.add_argument("--tree", type=Path)
    ap.add_argument("--rpc")
    ap.add_argument("--canonical-rpc", help="read-only canonical RPC for live snapshot finality (required for commit-root)")
    ap.add_argument("--params")
    ap.add_argument("--rehearsal", action="store_true")
    ap.add_argument("--execute-on-private-fork", action="store_true",
                    help="keep the executed transaction on the private anvil (rehearsal)")
    return ap.parse_args()


# ---------------------------------------------------------------------------------------------------------
# ABI
# ---------------------------------------------------------------------------------------------------------


def int_word(value: int) -> bytes:
    """A signed ABI word (two's complement), for int24 ticks."""
    return k.word(value % (1 << 256))


def dyn(data: bytes) -> bytes:
    return k.word(len(data)) + data + b"\x00" * (-len(data) % 32)


def encode(signature: str, *parts: bytes) -> bytes:
    return k.selector(signature) + b"".join(parts)


def pool_key_words(key: dict) -> bytes:
    return (k.addr_word(key["currency0"]) + k.addr_word(key["currency1"]) + k.word(key["fee"])
            + int_word(key["tickSpacing"]) + k.addr_word(key["hooks"]))


def settle_words(p: dict) -> bytes:
    """Params as an ABI tuple. It holds a dynamic array, so v2Ranges sits behind an offset that counts from the
    tuple's start, past its 16-word head."""
    head = (pool_key_words(p["oldKey"]) + k.word(p["v1In"]) + k.word(p["tailIn"]) + k.word(p["tailLimit"])
            + pool_key_words(p["newKey"]) + int_word(p["openTick"]) + k.word(16 * 32) + k.word(p["minWethOut"]))
    if len(head) != 16 * 32:
        k.fail("settle params head is not 16 words")
    ranges = k.word(len(p["v2Ranges"])) + b"".join(
        int_word(r["tickLower"]) + int_word(r["tickUpper"]) + k.word(r["liquidity"]) for r in p["v2Ranges"])
    return head + ranges


def settle_data(p: dict) -> bytes:
    """settle(Params): the dynamic tuple sits behind an offset."""
    return encode(SETTLE_SIG, k.word(32), settle_words(p))


def launch_args(d: dict, p: dict, backing: int, budget: int) -> bytes:
    """MigrationLaunch's constructor arguments: Config is static, its six words inline; Params is dynamic, behind
    an offset past those seven words."""
    config = (k.addr_word(d["safe"]) + k.addr_word(d["vault"]) + k.addr_word(d["v2"]) + k.addr_word(d["settler"])
              + k.word(backing) + k.word(budget))
    return config + k.word(7 * 32) + settle_words(p)


def launch_creation_code() -> bytes:
    if not LAUNCH_ARTIFACT.is_file():
        k.fail(f"no launch contract artifact at {LAUNCH_ARTIFACT}: run forge build in contracts/migration-launch")
    code = json.loads(LAUNCH_ARTIFACT.read_text())["bytecode"]["object"]
    return bytes.fromhex(code.removeprefix("0x"))


def create2_address(deployer: str, salt: bytes, init: bytes) -> str:
    return k.checksum("0x" + k.keccak(b"\xff" + bytes.fromhex(deployer[2:]) + salt + k.keccak(init))[12:].hex())


def cast_calldata(signature: str, *args: str) -> bytes:
    """The same calldata from foundry's encoder, for the second derivation."""
    out = k.run_tool(["cast", "calldata", signature, *args], k.PROJECT, timeout=60).strip()
    return bytes.fromhex(out[2:])


def key_arg(key: dict) -> str:
    return f"({key['currency0']},{key['currency1']},{key['fee']},{key['tickSpacing']},{key['hooks']})"


# ---------------------------------------------------------------------------------------------------------
# Chain
# ---------------------------------------------------------------------------------------------------------


def private_anvil(url: str, chain_id: int) -> k.Rpc:
    k.require_loopback(url)
    rpc = k.Rpc(url)
    version = rpc.call_or_none("web3_clientVersion", []) or ""
    if "anvil" not in version.lower():
        k.fail(f"--rpc is not an anvil ({version}); start a private fork: anvil --fork-url <Base RPC>")
    if rpc.chain_id() != chain_id:
        k.fail(f"RPC chainId {rpc.chain_id()} != params.chainId {chain_id}")
    return rpc


def view(rpc: k.Rpc, to: str, signature: str, *parts: bytes) -> bytes:
    out = rpc.call_or_none("eth_call", [{"to": to, "data": "0x" + encode(signature, *parts).hex()}, "latest"])
    if out is None or len(out) < 66:
        k.fail(f"{signature} on {to} reverted or returned nothing")
    return bytes.fromhex(out[2:])


def uint(rpc: k.Rpc, to: str, signature: str, *parts: bytes) -> int:
    return int.from_bytes(view(rpc, to, signature, *parts)[:32], "big")


def sint(rpc: k.Rpc, to: str, signature: str) -> int:
    return int.from_bytes(view(rpc, to, signature)[:32], "big", signed=True)


def address(rpc: k.Rpc, to: str, signature: str, *parts: bytes) -> str:
    return k.checksum("0x" + view(rpc, to, signature, *parts)[12:32].hex())


def text(rpc: k.Rpc, to: str, signature: str) -> str:
    raw = view(rpc, to, signature)
    offset = int.from_bytes(raw[:32], "big")
    length = int.from_bytes(raw[offset:offset + 32], "big")
    return raw[offset + 32:offset + 32 + length].decode()


def balance(rpc: k.Rpc, token: str, holder: str) -> int:
    return uint(rpc, token, "balanceOf(address)", k.addr_word(holder))


def code_hash(rpc: k.Rpc, target: str) -> str:
    return "0x" + k.keccak(bytes.fromhex(rpc.call("eth_getCode", [target, "latest"])[2:])).hex()


def sqrt_price(rpc: k.Rpc, pool_manager: str, pool_id: bytes) -> int:
    slot = k.keccak(pool_id + k.word(POOLS_SLOT))
    return uint(rpc, pool_manager, "extsload(bytes32)", slot) & ((1 << 160) - 1)


def send(rpc: k.Rpc, sender: str, to: str, data: bytes) -> dict:
    """A transaction from an impersonated account (private anvil only). Stops if it would revert."""
    tx = {"from": sender, "to": to, "data": "0x" + data.hex()}
    if int(rpc.call("eth_getBalance", [sender, "latest"]), 16) < 10**18:
        rpc.call("anvil_setBalance", [sender, hex(10**20)])
    estimate = rpc._request("eth_estimateGas", [tx, "latest"])
    if "error" in estimate:
        k.fail(f"the transaction from {sender} to {to} reverts on the fork: {json.dumps(estimate['error'])}")
    rpc.call("anvil_impersonateAccount", [sender])
    tx_hash = rpc.call("eth_sendTransaction", [tx | {"gas": hex(int(estimate["result"], 16) * 13 // 10)}])
    receipt = None
    for _ in range(400):  # anvil can hand back the hash a moment before the block is mined
        receipt = rpc.call("eth_getTransactionReceipt", [tx_hash])
        if receipt is not None:
            break
        time.sleep(0.05)
    rpc.call("anvil_stopImpersonatingAccount", [sender])
    if receipt is None or receipt["status"] != "0x1":
        k.fail(f"the transaction from {sender} to {to} failed on the fork: {tx_hash}")
    return receipt


# ---------------------------------------------------------------------------------------------------------
# The Safe
# ---------------------------------------------------------------------------------------------------------


def safe_tx(to: str, data: bytes, operation: int, nonce: int) -> dict:
    return {"to": k.checksum(to), "value": 0, "data": data, "operation": operation, "safeTxGas": 0,
            "baseGas": 0, "gasPrice": 0, "gasToken": ZERO, "refundReceiver": ZERO, "nonce": nonce}


def domain_separator(chain_id: int, safe: str) -> bytes:
    return k.keccak(DOMAIN_TYPEHASH + k.word(chain_id) + k.addr_word(safe))


def safe_tx_hash_python(chain_id: int, safe: str, tx: dict) -> bytes:
    struct = k.keccak(SAFE_TX_TYPEHASH + k.addr_word(tx["to"]) + k.word(tx["value"]) + k.keccak(tx["data"])
                      + k.word(tx["operation"]) + k.word(tx["safeTxGas"]) + k.word(tx["baseGas"])
                      + k.word(tx["gasPrice"]) + k.addr_word(tx["gasToken"]) + k.addr_word(tx["refundReceiver"])
                      + k.word(tx["nonce"]))
    return k.keccak(b"\x19\x01" + domain_separator(chain_id, safe) + struct)


def _head(tx: dict, last: bytes) -> list[bytes]:
    """execTransaction and getTransactionHash share their first nine arguments; `data` is at offset 320."""
    return [k.addr_word(tx["to"]), k.word(tx["value"]), k.word(320), k.word(tx["operation"]), k.word(tx["safeTxGas"]),
            k.word(tx["baseGas"]), k.word(tx["gasPrice"]), k.addr_word(tx["gasToken"]),
            k.addr_word(tx["refundReceiver"]), last]


def safe_tx_hash_on_chain(rpc: k.Rpc, safe: str, tx: dict) -> bytes:
    return view(rpc, safe, HASH_SIG, *_head(tx, k.word(tx["nonce"])), dyn(tx["data"]))[:32]


def safe_tx_hash(rpc: k.Rpc, chain_id: int, safe: str, tx: dict) -> bytes:
    py = safe_tx_hash_python(chain_id, safe, tx)
    chain = safe_tx_hash_on_chain(rpc, safe, tx)
    if py != chain:
        k.fail(f"safeTxHash mismatch: python EIP-712 0x{py.hex()} != Safe.getTransactionHash 0x{chain.hex()}")
    return py


def check_safe(rpc: k.Rpc, params: dict, safe: str, chain_id: int, nonce: int, rehearsal: bool) -> tuple[dict, list]:
    ext = params["external"]
    singleton = k.checksum("0x" + rpc.call("eth_getStorageAt", [safe, "0x0", "latest"])[-40:])
    if singleton != k.checksum(ext["safe141"]["singleton"]):
        k.fail(f"the Safe's singleton {singleton} is not Safe 1.4.1 {ext['safe141']['singleton']}")
    if text(rpc, safe, "VERSION()") != "1.4.1":
        k.fail("the Safe does not report VERSION 1.4.1")
    raw = view(rpc, safe, "getOwners()")
    count = int.from_bytes(raw[32:64], "big")
    owners = [k.checksum("0x" + raw[64 + 32 * i + 12:64 + 32 * (i + 1)].hex()) for i in range(count)]
    threshold = uint(rpc, safe, "getThreshold()")
    on_chain_nonce = uint(rpc, safe, "nonce()")
    if nonce != on_chain_nonce:
        k.fail(f"--safe-nonce {nonce} but the Safe's next nonce is {on_chain_nonce}: a transaction can only be "
               "simulated at the Safe's current nonce (execute or reject the queued ones first)")
    if view(rpc, safe, "domainSeparator()")[:32] != domain_separator(chain_id, safe):
        k.fail("the Safe's domainSeparator() != the Python EIP-712 domain separator")
    governance = params["governance"]
    if governance["owners"] != k.TBD and governance["threshold"] != k.TBD:
        want = sorted(k.checksum(o) for o in governance["owners"])
        if sorted(owners) != want or threshold != governance["threshold"]:
            k.fail(f"the Safe's owners/threshold ({owners}, {threshold}) != params governance ({want}, "
                   f"{governance['threshold']})")
    elif not rehearsal:
        print("note: governance.owners/threshold are TBD (§6.1); the Safe's on-chain owners are used as they are")
    checks = [f"Safe {safe}: singleton Safe 1.4.1, {threshold}-of-{len(owners)}, next nonce {nonce}",
              "Safe domainSeparator() == python EIP-712 domain {chainId, verifyingContract}"]
    return {"owners": owners, "threshold": threshold}, checks


def safe_settings(rpc: k.Rpc, safe: str) -> dict:
    """Everything that decides who controls the Safe: owners, threshold, modules, singleton, guard, fallback handler."""
    slots = (("singleton", "0x0"), ("guard", GUARD_SLOT), ("fallbackHandler", FALLBACK_HANDLER_SLOT))
    return {"owners": view(rpc, safe, "getOwners()").hex(), "threshold": uint(rpc, safe, "getThreshold()"),
            "modules": view(rpc, safe, "getModulesPaginated(address,uint256)", k.addr_word(SENTINEL), k.word(10)).hex()
            } | {name: rpc.call("eth_getStorageAt", [safe, slot, "latest"]) for name, slot in slots}


def exec_data(tx: dict, signatures: bytes) -> bytes:
    data = dyn(tx["data"])
    return encode(EXEC_SIG, *_head(tx, k.word(320 + len(data))), data, dyn(signatures))


def execute(rpc: k.Rpc, safe: str, owners: dict, tx: dict, tx_hash: bytes) -> dict:
    """approveHash from the first `threshold` owners by address, then execTransaction from a non-owner with
    their approved-hash signatures (r = owner, s = 0, v = 1), sorted by owner as the Safe requires."""
    approvers = sorted(owners["owners"], key=lambda o: int(o, 16))[:owners["threshold"]]
    for owner in approvers:
        send(rpc, owner, safe, encode("approveHash(bytes32)", tx_hash))
        if uint(rpc, safe, "approvedHashes(address,bytes32)", k.addr_word(owner), tx_hash) != 1:
            k.fail(f"approveHash from {owner} did not register")
    signatures = b"".join(k.addr_word(owner) + k.word(0) + b"\x01" for owner in approvers)
    receipt = send(rpc, EXECUTOR, safe, exec_data(tx, signatures))
    # The txHash is the event's first field, indexed or not depending on the Safe build.
    succeeded = any(log["address"].lower() == safe.lower() and log["topics"][0] == EXECUTION_SUCCESS
                    and tx_hash.hex() in (log["topics"][1][2:] if len(log["topics"]) > 1 else "", log["data"][2:66])
                    for log in receipt["logs"])
    if not succeeded:
        k.fail("execTransaction did not emit ExecutionSuccess for this safeTxHash (an inner call failed: GS013)")
    if uint(rpc, safe, "nonce()") != tx["nonce"] + 1:
        k.fail("the Safe nonce did not advance by one")
    return {"approvedBy": approvers, "block": int(receipt["blockNumber"], 16), "gasUsed": int(receipt["gasUsed"], 16)}


# ---------------------------------------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------------------------------------


def load_deployment(path: Path, params: dict, rpc: k.Rpc) -> tuple[dict, list]:
    """deployment.json ({"safe","token","vault","settler","hook","v2"}), with every link checked on chain."""
    if not path.is_file():
        k.fail(f"deployment file not found: {path}")
    raw = json.loads(path.read_text())
    missing = [key for key in ("safe", "token", "vault", "settler", "hook", "v2") if key not in raw]
    if missing:
        k.fail(f"{path}: missing {missing}")
    d = {key: k.checksum(raw[key]) for key in ("safe", "token", "vault", "settler", "hook", "v2")}
    if d["v2"] != d["token"]:
        k.fail(f"{path}: v2 {d['v2']} != token {d['token']}")
    for key, target in d.items():
        if rpc.call("eth_getCode", [target, "latest"]) in ("0x", "0x0"):
            k.fail(f"{key} {target}: no code on the fork")
    ext, pool = params["external"], params["successorPool"]
    minter = k.keccak(b"MINTER_ROLE")
    links = (
        ("vault.owner() == safe", address(rpc, d["vault"], "owner()") == d["safe"]),
        ("vault.V1() == params v1", address(rpc, d["vault"], "V1()") == k.checksum(ext["v1"])),
        ("vault.V2() == v2", address(rpc, d["vault"], "V2()") == d["v2"]),
        ("settler.SAFE() == safe", address(rpc, d["settler"], "SAFE()") == d["safe"]),
        ("settler.V1() == params v1", address(rpc, d["settler"], "V1()") == k.checksum(ext["v1"])),
        ("settler.V2() == v2", address(rpc, d["settler"], "V2()") == d["v2"]),
        ("settler.WETH() == params weth", address(rpc, d["settler"], "WETH()") == k.checksum(ext["weth"])),
        ("settler.POOL_MANAGER() == params poolManager",
         address(rpc, d["settler"], "POOL_MANAGER()") == k.checksum(ext["poolManager"])),
        ("settler.POSITION_MANAGER() == params positionManager",
         address(rpc, d["settler"], "POSITION_MANAGER()") == k.checksum(ext["positionManager"])),
        ("settler.V3_TAIL() == params v3Tail", address(rpc, d["settler"], "V3_TAIL()") == k.checksum(ext["v3Tail"])),
        ("settler.OLD_POOL_ID() == params oldPool.poolId",
         "0x" + view(rpc, d["settler"], "OLD_POOL_ID()")[:32].hex() == ext["oldPool"]["poolId"].lower()),
        ("settler.LP_FEE() == successorPool.lpFee", uint(rpc, d["settler"], "LP_FEE()") == pool["lpFee"]),
        ("settler.TICK_SPACING() == successorPool.tickSpacing",
         sint(rpc, d["settler"], "TICK_SPACING()") == pool["tickSpacing"]),
        ("hook address carries exactly the 0x2044 flags", (int(d["hook"], 16) & 0x3FFF) == 0x2044),
        ("hook.INITIALIZER() == settler", address(rpc, d["hook"], "INITIALIZER()") == d["settler"]),
        # The settler opens the pool only with a hook paying 1.5% to its FEE_RECIPIENT; fail here, before signing.
        ("hook.TREASURY() == settler.FEE_RECIPIENT()",
         address(rpc, d["hook"], "TREASURY()") == address(rpc, d["settler"], "FEE_RECIPIENT()")),
        ("hook.FEE_PIPS() == 15000 (1.5%)", uint(rpc, d["hook"], "FEE_PIPS()") == 15_000),
        ("v2 MINTER_ROLE is held by the Safe",
         uint(rpc, d["v2"], "hasRole(bytes32,address)", minter, k.addr_word(d["safe"])) == 1),
    )
    for label, ok in links:
        if not ok:
            k.fail(f"deployment check failed: {label}")
    return d, [f"deployment: {label}" for label, _ in links]


def load_params(args: argparse.Namespace) -> dict:
    return k.load_phase_params(args.params, rehearsal=args.rehearsal)


# ---------------------------------------------------------------------------------------------------------
# commitRoot
# ---------------------------------------------------------------------------------------------------------


def load_tree(path: Path, vault: str) -> tuple[bytes, int, int]:
    """Root, total and leaf count, recomputed from the leaves. A snapshot.json next to the tree (the snapshot
    phase writes one) must name the same vault and the tree's sha256."""
    if not path.is_file():
        k.fail(f"tree not found: {path}")
    tree = json.loads(path.read_text())
    snapshot = path.parent / "snapshot.json"
    if not snapshot.is_file():
        k.fail(f"mandatory snapshot missing: {snapshot}")
    s = json.loads(snapshot.read_text())
    if k.checksum(s["vault"]) != k.checksum(vault):
        k.fail(f"{snapshot} was taken of vault {s['vault']}, not the deployment's {vault}")
    if s["sha256"]["tree.json"] != k.sha256_file(path):
        k.fail(f"{path} does not match the sha256 its snapshot.json recorded")
    level, total, previous = [], 0, -1
    for i, leaf in enumerate(tree["leaves"]):
        account, amount = int(leaf["account"], 16), int(leaf["amount"])
        if leaf["index"] != i or account <= previous or amount == 0:
            k.fail(f"{path}: leaf {i} is out of order, repeated or zero")
        level.append(k.keccak(k.word(i) + account.to_bytes(20, "big") + k.word(amount)))
        total += amount
        previous = account
    if not level or len(level) != tree["leafCount"]:
        k.fail(f"{path}: leafCount does not match the leaves")
    while len(level) > 1:
        level = [k.keccak(min(level[j], level[j + 1]) + max(level[j], level[j + 1])) if j + 1 < len(level)
                 else level[j] for j in range(0, len(level), 2)]
    if "0x" + level[0].hex() != tree["root"].lower() or total != int(tree["total"]):
        k.fail(f"{path}: the leaves hash to 0x{level[0].hex()} / total {total}, not the recorded root and total")
    return level[0], total, len(tree["leaves"])


def commit_root(args, params: dict, rpc: k.Rpc, d: dict, owners: dict, checks: list) -> None:
    if args.tree is None:
        k.fail("commit-root needs --tree <tree.json> (the snapshot phase's output)")
    vault, chain_id = d["vault"], params["chainId"]
    root, total, leaves = load_tree(args.tree, vault)
    canonical_url = getattr(args, "canonical_rpc", None)
    if not args.rehearsal and not canonical_url:
        k.fail("live commit-root requires --canonical-rpc for finalized snapshot verification")
    authority = k.Rpc(canonical_url) if canonical_url else rpc
    s = snapshots.verify_snapshot(args.tree, rpc, vault, params, rehearsal=args.rehearsal, finality_rpc=authority)
    if (s["verification"]["root"] != "0x" + root.hex() or int(s["verification"]["total"]) != total
            or s["verification"]["leaves"] != leaves):
        k.fail("loaded signing root/total differs from ledger-verified snapshot")
    checks.append(f"tree: {leaves} leaves fold to root 0x{root.hex()}, total {total} (pure-Python keccak)")
    if uint(rpc, vault, "phase()") != 0 or view(rpc, vault, "root()")[:32] != b"\x00" * 32:
        k.fail("the vault is not open or already has a root")
    now = int(rpc.block()["timestamp"], 16)
    deposit_deadline = uint(rpc, vault, "DEPOSIT_DEADLINE()")
    commit_deadline = uint(rpc, vault, "COMMIT_DEADLINE()")
    if not deposit_deadline < now <= commit_deadline:
        k.fail(f"fork time {now} is outside the commit window ({deposit_deadline}, {commit_deadline}]")
    if uint(rpc, vault, "PRO_RATA_ENABLED()") == 1:
        net = uint(rpc, vault, "totalDepositedV1()") - uint(rpc, vault, "totalLedgerWithdrawnV1()")
        expected = net * uint(rpc, vault, "MIGRATION_RATE_BPS()") // 10_000
        if total != expected:
            k.fail(f"tree total {total} != the vault's pro-rata total {expected}: commitRoot would revert")
        checks.append(f"tree total == vault net ledger x rate / 10 000 = {expected} (the pro-rata check)")
    checks.append(f"fork time {now} is inside the commit window ({deposit_deadline}, {commit_deadline}]")

    data = encode("commitRoot(bytes32,uint256)", root, k.word(total))
    if data != cast_calldata("commitRoot(bytes32,uint256)", "0x" + root.hex(), str(total)):
        k.fail("commitRoot calldata differs from cast calldata")
    checks.append("commitRoot calldata == cast calldata")
    tx = safe_tx(vault, data, CALL, args.safe_nonce)
    tx_hash = safe_tx_hash(rpc, chain_id, d["safe"], tx)
    checks.append("safeTxHash: python EIP-712 == Safe.getTransactionHash on the fork")

    head = rpc.block()
    snap = rpc.call("evm_snapshot", [])
    run = execute(rpc, d["safe"], owners, tx, tx_hash)
    if view(rpc, vault, "root()")[:32] != root or uint(rpc, vault, "totalClaimable()") != total:
        k.fail("after execution the vault's root/totalClaimable are not the tree's")
    if uint(rpc, vault, "phase()") != PHASE_COMMITTED:
        k.fail("after execution the vault is not Committed")
    checks.append(f"executed through the Safe (approveHash x{len(run['approvedBy'])} + execTransaction): "
                  "vault root and totalClaimable == the tree, phase Committed")
    if not args.execute_on_private_fork:
        rpc.call("evm_revert", [snap])
    calls = [{"label": f"vault.commitRoot(0x{root.hex()}, {total})", "to": vault, "data": data}]
    write_outputs("commitRoot", "SURPLUS v2 migration: commitRoot", chain_id, d["safe"], tx, tx_hash, calls,
                  checks, {"forkBlock": fork_block(head), "execution": run, "tree": str(args.tree),
                           "root": "0x" + root.hex(), "totalClaimable": str(total), "leaves": leaves,
                           "snapshotVerification": s, "snapshotSha256": k.sha256_file(args.tree.parent / "snapshot.json"),
                           "keptOnPrivateFork": args.execute_on_private_fork})


# ---------------------------------------------------------------------------------------------------------
# The launch batch
# ---------------------------------------------------------------------------------------------------------


def launch_steps(d: dict, p: dict, backing: int, budget: int) -> list[dict]:
    """The five calls the launch contract makes as the Safe, in order: the record of what the signed launch does."""
    vault, settler, v2 = d["vault"], d["settler"], d["v2"]
    return [
        {"label": f"v2.mint(vault {vault}, {backing})", "to": v2,
         "data": encode("mint(address,uint256)", k.addr_word(vault), k.word(backing))},
        {"label": "vault.activateClaims()", "to": vault, "data": encode("activateClaims()")},
        {"label": f"vault.withdrawV1ForSettlement(settler {settler}, {p['v1In']})", "to": vault,
         "data": encode("withdrawV1ForSettlement(address,uint256)", k.addr_word(settler), k.word(p["v1In"]))},
        {"label": f"v2.mint(settler {settler}, {budget})", "to": v2,
         "data": encode("mint(address,uint256)", k.addr_word(settler), k.word(budget))},
        {"label": "settler.settle(params)", "to": settler, "data": settle_data(p)},
    ]


def settle_params(params: dict, rpc: k.Rpc, d: dict, v1_in: int) -> tuple[dict, dict]:
    """The unsigned settle() params: the seed (kit/seed.py; v2 opens at v1's pre-sale tick on the old pool rounded
    to the grid, so at 1:1 every migrator keeps its value within half a tick spacing), and sale.tailShareBps of the
    v1 sold on the v3 tail, the rest on the Doppler pool."""
    ext, pool, sale = params["external"], params["successorPool"], params["sale"]
    old = ext["oldPool"]
    old_key = {"currency0": k.checksum(old["currency0"]), "currency1": k.checksum(old["currency1"]),
               "fee": old["fee"], "tickSpacing": old["tickSpacing"], "hooks": k.checksum(old["hooks"])}
    if "0x" + k.keccak(pool_key_words(old_key)).hex() != old["poolId"].lower():
        k.fail("params external.oldPool does not hash to its poolId")
    weth, v2 = k.checksum(ext["weth"]), d["v2"]
    if k.checksum(old["currency0"]) != weth or k.checksum(old["currency1"]) != k.checksum(ext["v1"]):
        k.fail("the old pool is not WETH/v1 (currency0 WETH): the opening-price rule below assumes it")
    v2_first = int(v2, 16) < int(weth, 16)
    new_key = {"currency0": v2 if v2_first else weth, "currency1": weth if v2_first else v2,
               "fee": pool["lpFee"], "tickSpacing": pool["tickSpacing"], "hooks": d["hook"]}
    built = seeds.build(rpc, params, v2_first)
    p = {"oldKey": old_key, "v1In": v1_in, "tailIn": v1_in * sale["tailShareBps"] // 10_000,
         "tailLimit": int(sale["tailSqrtPriceLimitX96"]), "newKey": new_key, "openTick": built["openTick"],
         "v2Ranges": built["v2Ranges"], "minWethOut": 0}
    return p, built


def settle_params_json(p: dict) -> dict:
    """The params as recorded: amounts as strings, ticks as numbers."""
    out = {}
    for key, value in p.items():
        if key == "v2Ranges":
            out[key] = [r | {"liquidity": str(r["liquidity"])} for r in value]
        elif isinstance(value, int) and key != "openTick":
            out[key] = str(value)
        else:
            out[key] = value
    return out


def receipt_of(rpc: k.Rpc, settler: str) -> dict:
    return {name: uint(rpc, settler, f"{name}()") for name in RECEIPT}


def deploy_launch(rpc: k.Rpc, deployer: str, init: bytes) -> str:
    """CREATE2 through the pinned deployer. Code at create2(deployer, salt, keccak(init)) can only be what `init`
    built, so the address alone names the contract and all its numbers; an existing copy is reused."""
    target = create2_address(deployer, LAUNCH_SALT, init)
    if rpc.call("eth_getCode", [target, "latest"]) in ("0x", "0x0"):
        send(rpc, EXECUTOR, deployer, LAUNCH_SALT + init)
    if rpc.call("eth_getCode", [target, "latest"]) in ("0x", "0x0"):
        k.fail(f"the launch contract did not deploy at {target}")
    return target


def run_launch(rpc: k.Rpc, d: dict, owners: dict, chain_id: int, nonce: int, p: dict, backing: int,
               budget: int) -> tuple[dict, bytes, dict, dict]:
    """Deploys a launch contract for these numbers, then executes the Safe's DELEGATECALL to its launch()."""
    init = launch_creation_code() + launch_args(d, p, backing, budget)
    contract = deploy_launch(rpc, d["create2_deployer"], init)
    tx = safe_tx(contract, encode("launch()"), DELEGATECALL, nonce)
    tx_hash = safe_tx_hash(rpc, chain_id, d["safe"], tx)
    run = execute(rpc, d["safe"], owners, tx, tx_hash)
    launch = {"address": contract, "init": init, "runtimeCodeHash": code_hash(rpc, contract)}
    return tx, tx_hash, launch, run | receipt_of(rpc, d["settler"])


def launch_batch(args, params: dict, rpc: k.Rpc, d: dict, owners: dict, checks: list) -> None:
    k.need(params, "successorPool", "sale")
    ext, sale, chain_id = params["external"], params["sale"], params["chainId"]
    vault, settler, v2, safe = d["vault"], d["settler"], d["v2"], d["safe"]
    deployer = k.checksum(ext["create2Deployer"])
    if rpc.call("eth_getCode", [deployer, "latest"]) in ("0x", "0x0"):
        k.fail(f"no CREATE2 deployer at {deployer} (params external.create2Deployer)")
    d = d | {"create2_deployer": deployer}
    k.run_tool(["forge", "build", "--deny", "warnings"], k.PROJECT, timeout=590)  # the artifact deployed below

    # Both amounts come from the vault: the backing it will check, and the v1 its ledger holds.
    if uint(rpc, vault, "phase()") != PHASE_COMMITTED or uint(rpc, vault, "claimsEverActive()") != 0:
        k.fail("the vault is not Committed with claims never activated: execute commitRoot first")
    backing = uint(rpc, vault, "totalClaimable()")
    v1_in = uint(rpc, vault, "totalDepositedV1()") - uint(rpc, vault, "totalLedgerWithdrawnV1()")
    v1 = k.checksum(ext["v1"])
    custody = balance(rpc, v1, vault)
    if backing == 0 or v1_in == 0 or custody < v1_in:
        k.fail(f"vault backing {backing}, net ledger {v1_in}, v1 held {custody}: nothing coherent to launch")
    checks.append(f"from the vault: backing = totalClaimable() = {backing}; v1In = net ledger = {v1_in} "
                  f"(v1 held {custody})")
    p, built = settle_params(params, rpc, d, v1_in)
    old_sqrt = built["oldSqrtPriceX96"]
    checks.append(f"seed: opens at tick {p['openTick']} (the old pool's tick {built['oldTick']} rounded to the "
                  f"{p['newKey']['tickSpacing']} grid); v2 side = {len(p['v2Ranges'])} range(s) copying the "
                  f"{built['v1AboveOldPrice']} v1 the old pool holds above its price; WETH side "
                  f"[{built['wethSide']['tickLower']}, {built['wethSide']['tickUpper']}]")
    new_id = k.keccak(pool_key_words(p["newKey"]))
    if sqrt_price(rpc, ext["poolManager"], new_id) != 0:
        k.fail(f"the successor pool 0x{new_id.hex()} is already initialized: the launch would revert")
    cap = uint(rpc, v2, "cap()")
    supply = uint(rpc, v2, "totalSupply()")
    headroom = cap - supply - backing
    head = rpc.block()

    # 1. Unconstrained: a launch contract with no floor and the whole remaining cap as budget.
    snap = rpc.call("evm_snapshot", [])
    _, _, free_launch, free = run_launch(rpc, d, owners, chain_id, args.safe_nonce, p, backing, headroom)
    free["oldSqrtPriceX96After"] = sqrt_price(rpc, ext["poolManager"], bytes.fromhex(ext["oldPool"]["poolId"][2:]))
    rpc.call("evm_revert", [snap])
    if (uint(rpc, safe, "nonce()") != args.safe_nonce or uint(rpc, vault, "claimsActive()") != 0
            or rpc.call("eth_getCode", [free_launch["address"], "latest"]) not in ("0x", "0x0")):
        k.fail("the fork did not return to the pre-simulation state")
    if free["v2Seeded"] != built["v2Need"]:
        k.fail(f"the v2 side took {free['v2Seeded']}, the kit's v4 rounding of the signed ranges says "
               f"{built['v2Need']}")
    checks.append(f"unconstrained run (a launch contract with minWethOut 0 and budget = cap - supply - backing = "
                  f"{headroom}): executed, raised {free['wethRaised']} WETH, used {free['v2Seeded']} v2 (= the signed "
                  "ranges' need); state reverted")

    # 2. The signed limits. The v2 side depends on the signed ranges alone, so its budget needs no drift margin.
    p["minWethOut"] = free["wethRaised"] * sale["minWethOutBps"] // 10_000
    used = free["v2Seeded"]
    budget = used + int(sale["v2BudgetExtraWei"])
    if budget > headroom:
        k.fail(f"the signed budget {budget} exceeds the v2 cap headroom {headroom}")

    # 3. The signed launch contract, from the same pre-state.
    snap = rpc.call("evm_snapshot", [])
    settings = safe_settings(rpc, safe)
    tx, tx_hash, launch, signed = run_launch(rpc, d, owners, chain_id, args.safe_nonce, p, backing, budget)
    contract, init = launch["address"], launch["init"]
    constructor_args = launch_args(d, p, backing, budget)
    signed["oldSqrtPriceX96After"] = sqrt_price(rpc, ext["poolManager"], bytes.fromhex(ext["oldPool"]["poolId"][2:]))
    weth = k.checksum(ext["weth"])
    settlement = view(rpc, vault, "verifySettlement()")
    funded, v2_held, claimable, v1_left, active = (int.from_bytes(settlement[32 * i:32 * (i + 1)], "big")
                                                   for i in range(5))
    first, count = signed["firstPositionId"], signed["positionCount"]
    owned = count == len(p["v2Ranges"]) + 1 and all(
        address(rpc, ext["positionManager"], "ownerOf(uint256)", k.word(i)) == safe
        for i in range(first, first + count))
    v1_above, slack = built["v1AboveOldPrice"], built["copySlack"]
    stored = k.word(32) + settle_words(p)  # abi.encode(params): what the contract stores and settleParams() returns
    getters = (
        ("SAFE()", address(rpc, contract, "SAFE()"), safe), ("VAULT()", address(rpc, contract, "VAULT()"), vault),
        ("SETTLER()", address(rpc, contract, "SETTLER()"), settler), ("V2()", address(rpc, contract, "V2()"), v2),
        ("V1()", address(rpc, contract, "V1()"), v1), ("WETH()", address(rpc, contract, "WETH()"), weth),
        ("V2_FOR_CLAIMS()", uint(rpc, contract, "V2_FOR_CLAIMS()"), backing),
        ("V1_FOR_SALE()", uint(rpc, contract, "V1_FOR_SALE()"), v1_in),
        ("V2_FOR_POOL()", uint(rpc, contract, "V2_FOR_POOL()"), budget),
        ("V1_SOLD_ON_V3_TAIL()", uint(rpc, contract, "V1_SOLD_ON_V3_TAIL()"), p["tailIn"]),
        ("MIN_WETH_OUT()", uint(rpc, contract, "MIN_WETH_OUT()"), p["minWethOut"]),
        ("OPEN_TICK()", sint(rpc, contract, "OPEN_TICK()"), p["openTick"]),
        ("NEW_POOL_ID()", view(rpc, contract, "NEW_POOL_ID()")[:32], new_id),
        ("V2_RANGES()", uint(rpc, contract, "V2_RANGES()"), len(p["v2Ranges"])),
        ("SETTLE_PARAMS_HASH()", view(rpc, contract, "SETTLE_PARAMS_HASH()")[:32], k.keccak(stored)),
        ("settleParams()", view(rpc, contract, "settleParams()"), stored),
    )
    post = (
        (f"launch contract {contract} = CREATE2({deployer}, salt 0x{LAUNCH_SALT.hex()}, keccak(MigrationLaunch "
         "creation code + constructor args))", contract == create2_address(deployer, LAUNCH_SALT, init)),
        ("its getters and settleParams() == the signed numbers ("
         + ", ".join(name for name, _, _ in getters) + ")", all(got == want for _, got, want in getters)),
        (f"wethRaised {signed['wethRaised']} >= minWethOut {p['minWethOut']}", signed["wethRaised"] >= p["minWethOut"]),
        ("wethRaised == the unconstrained run's (same pre-state)", signed["wethRaised"] == free["wethRaised"]),
        (f"v2 used {signed['v2Seeded']} <= budget {budget}", signed["v2Seeded"] <= budget),
        ("vault.claimsActive() and verifySettlement(): fully funded, v2 held == backing, claimable == backing",
         active == 1 and funded == 1 and v2_held == backing and claimable == backing),
        (f"vault v1 left == v1 held - v1In ({custody - v1_in})", v1_left == custody - v1_in),
        (f"v2 side {signed['v2Seeded']} == the signed ranges' need {built['v2Need']}",
         signed["v2Seeded"] == built["v2Need"]),
        (f"the v2 side copies the {v1_above} v1 the old pool held above its price, at most {slack} wei short",
         signed["v2Seeded"] <= v1_above and v1_above - signed["v2Seeded"] <= slack),
        (f"the WETH side holds what the sale raised (wethSeeded {signed['wethSeeded']}, at most 1e-5 short)",
         signed["wethRaised"] - signed["wethSeeded"] <= signed["wethRaised"] // 100_000),
        (f"LP NFTs {first}..{first + count - 1} (the WETH side, then each v2 range) owned by the Safe", owned),
        ("the settler holds no v1, WETH or v2",
         balance(rpc, v1, settler) == 0 and balance(rpc, weth, settler) == 0 and balance(rpc, v2, settler) == 0),
        ("the successor pool opened at the signed tick's price",
         sqrt_price(rpc, ext["poolManager"], new_id) == seeds.sqrt_at(p["openTick"])),
        ("v2 supply == before + backing + budget", uint(rpc, v2, "totalSupply()") == supply + backing + budget),
        ("the Safe's owners, threshold, modules, singleton, guard and fallback handler are unchanged",
         safe_settings(rpc, safe) == settings),
    )
    for label, ok in post:
        if not ok:
            k.fail(f"signed launch simulation check failed: {label}")
    checks.append("signed run executed through the Safe (approveHash + execTransaction, DELEGATECALL to the "
                  "launch contract's launch()) and passed:")
    checks += [f"  {label}" for label, _ in post]
    if not args.execute_on_private_fork:
        rpc.call("evm_revert", [snap])

    ranges_arg = ",".join(f"({r['tickLower']},{r['tickUpper']},{r['liquidity']})" for r in p["v2Ranges"])
    settle_args = (f"({key_arg(p['oldKey'])},{p['v1In']},{p['tailIn']},{p['tailLimit']},{key_arg(p['newKey'])},"
                   f"{p['openTick']},[{ranges_arg}],{p['minWethOut']})")
    config_arg = f"({safe},{vault},{v2},{settler},{backing},{budget})"
    cast_args = k.run_tool(["cast", "abi-encode", LAUNCH_CONSTRUCTOR, config_arg, settle_args], k.PROJECT,
                           timeout=60).strip()
    if bytes.fromhex(cast_args.removeprefix("0x")) != constructor_args:
        k.fail("the launch contract's constructor args differ from cast abi-encode")
    if cast_calldata(SETTLE_SIG, settle_args) != settle_data(p):
        k.fail("settle calldata differs from cast calldata")
    if cast_calldata("launch()") != tx["data"]:
        k.fail("launch() calldata differs from cast calldata")
    checks.append("constructor args, the settle params and launch() == cast abi-encode / cast calldata")
    steps = launch_steps(d, p, backing, budget)

    def amounts(r: dict) -> dict:
        return {key: str(r[key]) for key in (*RECEIPT, "oldSqrtPriceX96After")} | {"gasUsed": r["gasUsed"]}

    simulation = {
        "chainId": chain_id,
        "forkBlock": fork_block(head),
        "safe": safe,
        "safeNonce": args.safe_nonce,
        "fromVault": {"backing": str(backing), "v1In": str(v1_in), "v1Held": str(custody)},
        "v2": {"cap": str(cap), "supplyBefore": str(supply), "headroom": str(headroom)},
        "sale": {"v1In": str(p["v1In"]), "tailIn": str(p["tailIn"]), "tailLimit": str(p["tailLimit"]),
                 "oldPoolId": ext["oldPool"]["poolId"], "oldSqrtPriceX96Before": str(old_sqrt)},
        "opening": {"newPoolId": "0x" + new_id.hex(), "newKey": p["newKey"], "openTick": p["openTick"],
                    "openSqrtPriceX96": str(seeds.sqrt_at(p["openTick"])), "oldTick": built["oldTick"],
                    "wethSide": built["wethSide"],
                    "v2Side": {"v1AboveOldPrice": str(v1_above), "need": str(built["v2Need"]),
                               "copySlack": str(slack), "ranges": settle_params_json(p)["v2Ranges"],
                               "oldPoolBlocks": built["blocks"]}},
        "unconstrained": {"minWethOut": "0", "v2Budget": str(headroom),
                          "launchContract": free_launch["address"]} | amounts(free),
        "rule": (f"minWethOut = wethRaised x {sale['minWethOutBps']} / 10000; v2Budget = v2Seeded + "
                 f"{sale['v2BudgetExtraWei']} wei"),
        "signed": {"minWethOut": str(p["minWethOut"]), "v2Budget": str(budget), "safeTxHash": "0x" + tx_hash.hex(),
                   "launchContract": contract, "runtimeCodeHash": launch["runtimeCodeHash"]} | amounts(signed),
        "keptOnPrivateFork": args.execute_on_private_fork,
    }
    k.write_json(OUT / "simulation.json", simulation)
    deploy = {
        "chainId": chain_id,
        "send": {"to": deployer, "value": "0", "data": "0x" + (LAUNCH_SALT + init).hex()},
        "note": ("Send this BEFORE the Safe transaction executes, from any funded account: a Safe DELEGATECALL to an "
                 "address with no code succeeds and does nothing. Then the code at launchContract must hash to "
                 "runtimeCodeHash. Anyone may send it; CREATE2 makes every copy the same contract."),
        "launchContract": contract,
        "runtimeCodeHash": launch["runtimeCodeHash"],
        "create2": {"deployer": deployer, "salt": "0x" + LAUNCH_SALT.hex(),
                    "initCodeHash": "0x" + k.keccak(init).hex()},
        "constructorArgs": "0x" + constructor_args.hex(),
        "config": {"safe": safe, "vault": vault, "v2": v2, "settler": settler, "v2ForClaims": str(backing),
                   "v2ForPool": str(budget)},
        "settleParams": settle_params_json(p),
        "verify": (f"cd contracts/migration-launch && forge verify-contract {contract} "
                   f"src/MigrationLaunch.sol:MigrationLaunch --chain {chain_id} --constructor-args "
                   f"0x{constructor_args.hex()} --watch"),
    }
    k.write_json(OUT / "launch-batch.deploy.json", deploy)
    write_outputs("launch-batch", "SURPLUS v2 launch", chain_id, safe, tx, tx_hash, steps, checks,
                  {"forkBlock": fork_block(head), "execution": {key: signed[key] for key in ("approvedBy", "block",
                                                                                             "gasUsed")},
                   "launchContract": {"address": contract, "runtimeCodeHash": launch["runtimeCodeHash"],
                                      "deploy": "launch-batch.deploy.json",
                                      "callsAreMadeBy": "the launch contract, as the Safe (DELEGATECALL)"},
                   "settleParams": settle_params_json(p),
                   "keptOnPrivateFork": args.execute_on_private_fork}, builder=False)
    print(f"  simulation: raised {free['wethRaised']} WETH, used {used} v2 in {len(p['v2Ranges'])} range(s) -> "
          f"signed minWethOut {p['minWethOut']}, v2 budget {budget}; launch contract {contract}")


# ---------------------------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------------------------


def fork_block(head: dict) -> dict:
    return {"number": int(head["number"], 16), "hash": head["hash"], "timestamp": int(head["timestamp"], 16)}


def write_outputs(name: str, title: str, chain_id: int, safe: str, tx: dict, tx_hash: bytes, calls: list[dict],
                  checks: list[str], extra: dict, builder: bool = True) -> None:
    """builder=False for a DELEGATECALL: the Transaction Builder can only produce CALLs, so its import file would
    send a different transaction."""
    op = "DELEGATECALL" if tx["operation"] == DELEGATECALL else "CALL"
    safe_tx_hash_hex = "0x" + tx_hash.hex()
    builder_json = {
        "version": "1.0",
        "chainId": str(chain_id),
        "createdAt": 0,
        "meta": {"name": title, "description": f"{title}. Safe {safe}, nonce {tx['nonce']}, {len(calls)} call(s); "
                                                f"safeTxHash {safe_tx_hash_hex}",
                 "txBuilderVersion": TX_BUILDER_VERSION, "createdFromSafeAddress": safe,
                 "createdFromOwnerAddress": "", "checksum": ""},
        "transactions": [{"to": c["to"], "value": "0", "data": "0x" + c["data"].hex(), "contractMethod": None,
                          "contractInputsValues": None} for c in calls],
    }
    if builder:
        k.write_json(OUT / f"{name}.json", builder_json)
    else:
        (OUT / f"{name}.json").unlink(missing_ok=True)  # an earlier batch's import would send the wrong transaction
    lines = [f"{'safe':15} {safe} (chain {chain_id})", f"{'to':15} {tx['to']}", f"{'value':15} 0",
             f"{'operation':15} {tx['operation']} ({op})", f"{'safeTxGas':15} 0", f"{'baseGas':15} 0",
             f"{'gasPrice':15} 0", f"{'gasToken':15} {ZERO}", f"{'refundReceiver':15} {ZERO}",
             f"{'nonce':15} {tx['nonce']}", f"{'safeTxHash':15} {safe_tx_hash_hex}", f"{'data':15} 0x{tx['data'].hex()}"]
    (OUT / f"{name}.calldata.txt").write_text("\n".join(lines) + "\n")
    (OUT / f"{name}.safeTxHash.txt").write_text(safe_tx_hash_hex + "\n")
    k.write_json(OUT / f"{name}.safe-tx.json", {
        "chainId": chain_id,
        "safe": safe,
        "safeTxHash": safe_tx_hash_hex,
        "domainSeparator": "0x" + domain_separator(chain_id, safe).hex(),
        "execTransaction": {"to": tx["to"], "value": "0", "data": "0x" + tx["data"].hex(), "operation": tx["operation"],
                            "safeTxGas": "0", "baseGas": "0", "gasPrice": "0", "gasToken": ZERO,
                            "refundReceiver": ZERO, "nonce": tx["nonce"]},
        "calls": [{"label": c["label"], "to": c["to"], "data": "0x" + c["data"].hex()} for c in calls],
        "checks": checks,
    } | extra)
    print(f"{name}: safeTxHash {safe_tx_hash_hex} (Safe {safe}, nonce {tx['nonce']}, {op} to {tx['to']})")
    for line in checks:
        print(f"  ok  {line}")
    shown = OUT.relative_to(k.PROJECT) if OUT.is_relative_to(k.PROJECT) else OUT  # a wrapper may point OUT elsewhere
    files = "json" if builder else "deploy.json"
    print(f"  wrote {shown}/{name}.{{{files},calldata.txt,safeTxHash.txt,safe-tx.json}}")


def main() -> None:
    args = parse_args()
    if k.keccak(DOMAIN_TYPE) != DOMAIN_TYPEHASH or k.keccak(SAFE_TX_TYPE) != SAFE_TX_TYPEHASH:
        k.fail("the Safe 1.4.1 type hashes do not match their type strings")
    params = load_params(args)
    rpc = private_anvil(k.rpc_url(args.rpc), params["chainId"])
    deployment, checks = load_deployment(args.deployment, params, rpc)
    owners, safe_checks = check_safe(rpc, params, deployment["safe"], params["chainId"], args.safe_nonce,
                                     args.rehearsal)
    checks = safe_checks + checks
    if args.tx == "commit-root":
        commit_root(args, params, rpc, deployment, owners, checks)
    else:
        launch_batch(args, params, rpc, deployment, owners, checks)



if __name__ == "__main__":
    main()
