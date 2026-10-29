#!/usr/bin/env python3
"""Isolated, unsigned Base Sepolia preparation. No signing or transaction RPC methods."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import time
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import kitlib as k
import safe_txs as safe
import snapshot as snapshots
from deploy_plan import create2

CHAIN = 84532
ZERO = safe.ZERO


def require(condition, message):
    if not condition:
        raise ValueError(message)


def address(value) -> str:
    require(isinstance(value, str) and re.fullmatch(r"0x[0-9a-fA-F]{40}", value), "invalid address literal")
    letters = value[2:]
    require(letters.islower() or letters.isupper() or not any(c.isalpha() for c in letters)
            or k.checksum(value) == value, "invalid address checksum; input is not repaired")
    require(int(value, 16) > 1, "zero/sentinel address forbidden")
    return value


def integer(value, minimum=0, maximum=(1 << 256) - 1) -> int:
    require(type(value) is int and minimum <= value <= maximum, "invalid integer or TBD decision")
    return value


def keys(obj, expected):
    require(isinstance(obj, dict) and set(obj) == set(expected.split()), "missing/unknown fields; no secrets accepted")


def validate(p, now=None, *, for_deployment=True):
    now = int(time.time()) if now is None else now
    keys(p, "schema mode chainId validUntil deployer governance token vault")
    require(not k.tbd_paths(p), "Bill's open decisions: " + ", ".join(k.tbd_paths(p)))
    integer(p["schema"], 1, 1)
    integer(p["chainId"], CHAIN, CHAIN)
    require(p["mode"] == "testnet", "only explicit testnet / 84532")
    integer(p["validUntil"], 1)
    if for_deployment:
        integer(p["validUntil"], now + 1, now + 7 * 86400)
    address(p["deployer"])
    g = p["governance"]
    keys(g, "owners threshold saltNonce")
    require(isinstance(g["owners"], list) and 2 <= len(g["owners"]) <= 20, "owners require an explicit quorum")
    for owner in g["owners"]:
        address(owner)
    require(len({x.lower() for x in g["owners"]}) == len(g["owners"]), "duplicate owners")
    require(p["deployer"].lower() not in {x.lower() for x in g["owners"]}, "deployer must not be a governance signer")
    integer(g["threshold"], 2, len(g["owners"]))
    integer(g["saltNonce"])
    t = p["token"]
    keys(t, "name symbol capWei")
    require(t["name"] == "TEST ONLY Surplus V2" and t["symbol"] == "TEST-V2", "test-only token metadata required")
    require(t["capWei"] == "1000000000000000000000000", "fixture cap must equal the V1 cap")
    v = p["vault"]
    keys(v, "depositDeadline commitDeadline executionWindowSeconds claimPeriodSeconds rateBps proRata")
    integer(v["depositDeadline"], 1)
    integer(v["commitDeadline"], v["depositDeadline"] + 1, p["validUntil"])
    integer(v["executionWindowSeconds"], 1, 86400)
    require(v["commitDeadline"] + v["executionWindowSeconds"] <= p["validUntil"], "params expire before execution window")
    integer(v["claimPeriodSeconds"], 0, 0)
    require(v["rateBps"] == 10000 and v["proRata"] is True,
            "only 1:1 pro-rata, no-expiry fixtures")
    return p


class ReadRpc(k.Rpc):
    ALLOWED = {"eth_chainId", "web3_clientVersion", "eth_getBlockByNumber", "eth_getCode", "eth_call",
               "eth_getStorageAt", "eth_getLogs", "eth_getTransactionCount", "eth_getTransactionReceipt",
               "eth_getBalance", "anvil_nodeInfo"}

    def __init__(self, url, at=None):
        super().__init__(url)
        self.at = at

    def _request(self, method, params):
        require(method in self.ALLOWED, "read-only RPC: method forbidden")
        if self.at is not None:
            params = [hex(self.at) if item == "latest" else item for item in params]
        self._id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params}).encode()
        request = k.urllib.request.Request(self._url, body, {"Content-Type": "application/json",
                                                          "User-Agent": "surplus-testnet-preparation/1"})
        try:
            with k.urllib.request.urlopen(request, timeout=60) as response:
                reply = json.loads(response.read())
        except Exception as error:
            raise ValueError("RPC transport: " + k.scrub(str(error))) from None
        require(isinstance(reply, dict) and reply.get("id") == self._id and ("result" in reply or "error" in reply),
                "invalid RPC response")
        return reply


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def dependencies():
    return json.loads((HERE / "dependencies.json").read_text())


def block_id(head):
    require(isinstance(head, dict) and re.fullmatch(r"0x[0-9a-fA-F]{64}", head.get("hash", "")), "invalid block header")
    return {"number": int(head["number"], 16), "hash": head["hash"], "timestamp": int(head["timestamp"], 16)}


def decode_bytes(raw):
    data = bytes.fromhex(raw[2:])
    require(len(data) >= 64 and int.from_bytes(data[:32], "big") == 32, "invalid dynamic ABI data")
    size = int.from_bytes(data[32:64], "big")
    require(size > 0 and len(data) == 64 + ((size + 31) // 32) * 32, "invalid ABI length")
    return data[64:64 + size]


def preflight(p, rpc, tag="finalized", local=False):
    require(rpc.chain_id() == CHAIN, "RPC must be Base Sepolia 84532")
    validate(p, block_id(rpc.block())["timestamp"])
    version = rpc.call("web3_clientVersion", [])
    require(local or "anvil" not in version.lower(), "Anvil is local evidence, not public finality")
    require(local or tag in ("safe", "finalized"), "public preflight requires safe/finalized pin")
    pin = block_id(rpc.block(tag))
    validate(p, pin["timestamp"])
    deps = dependencies()
    for name, dep in deps["contracts"].items():
        code = rpc.call("eth_getCode", [dep["address"], hex(pin["number"])])
        require("0x" + k.keccak(bytes.fromhex(code[2:])).hex() == dep["runtimeCodeHash"], name + " code hash mismatch")
    proxy = decode_bytes(rpc.eth_call(deps["contracts"]["proxyFactory"]["address"],
                                     "0x" + k.selector("proxyCreationCode()").hex(), pin["number"]))
    require(block_id(rpc.block(pin["number"])) == pin, "pin changed during preflight")
    return {"chainId": CHAIN, "scope": "local-rehearsal" if local else "public-read-only",
            "paramsHash": digest(p), "block": pin, "finality": tag, "dependencies": deps,
            "proxyCreationCode": "0x" + proxy.hex()}


def save(path, value):
    path = Path(path).resolve()
    repo = k.CONTRACTS.parent.resolve()
    require(not path.is_relative_to(repo) or path.is_relative_to(HERE / "output"),
            "testnet artifacts must not overwrite production or source paths")
    encoded = json.dumps(value, indent=2, sort_keys=True) + "\n"
    require(not path.exists() or path.read_text() == encoded, "immutable output differs; select a new output path")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(encoded)


ARTIFACTS = {
    "v1": ("migration-launch", "TestnetV1.sol/TestnetV1.json", "src/testnet/TestnetV1.sol:TestnetV1"),
    "implementation": ("token-v2", "SurplusTokenV2BaseSepolia.sol/SurplusTokenV2BaseSepolia.json",
                       "src/SurplusTokenV2BaseSepolia.sol:SurplusTokenV2BaseSepolia"),
    "token": ("migration-launch", "ERC1967Proxy.sol/ERC1967Proxy.json",
              "../../node_modules/@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy"),
    "vault": ("migration-launch", "MigrationVault.sol/MigrationVault.json",
              "../migration/src/MigrationVault.sol:MigrationVault"),
}


def sources():
    files = []
    for project, patterns in {
        "token-v2": ("src/**/*.sol", "scripts/*", "foundry.toml", "remappings.txt"),
        "migration": ("src/**/*.sol",),
        "migration-launch": ("src/**/*.sol", "script/*.sol", "kit/*.py", "kit/testnet/*.py",
                             "kit/testnet/*.json", "foundry.toml", "remappings.txt"),
    }.items():
        for pattern in patterns:
            files.extend(path for path in (k.CONTRACTS / project).glob(pattern) if path.is_file())
    return {str(path.relative_to(k.CONTRACTS)): k.sha256_file(path) for path in sorted(set(files))}


def artifacts():
    k.run_tool([sys.executable, "scripts/sepolia_source.py", "--check"], k.CONTRACTS / "token-v2")
    for project in ("token-v2", "migration-launch"):
        k.run_tool(["forge", "build", "--deny", "warnings"], k.CONTRACTS / project)
    return {name: json.loads((k.CONTRACTS / project / "out" / file).read_text())
            for name, (project, file, _) in ARTIFACTS.items()}


def abi(signature, *args):
    return bytes.fromhex(k.run_tool(["cast", "abi-encode", signature, *map(str, args)], k.PROJECT).strip()[2:])


def make_plan(p, proof, for_deployment=True):
    # Historical identity retains the approval bound at its canonical preflight pin.
    validate(p, integer(proof["block"]["timestamp"], 1))
    if for_deployment:
        validate(p)
        require(int(time.time()) < p["vault"]["depositDeadline"], "deployment window closed")
    require(proof["chainId"] == CHAIN and proof["paramsHash"] == digest(p), "preflight params/chain mismatch")
    require(proof["dependencies"] == dependencies(), "stale dependency proof")
    require(proof["proxyCreationCode"] == dependencies()["proxyCreationCode"], "wrong Safe proxy creation code")
    require(proof["block"]["timestamp"] < p["vault"]["depositDeadline"], "deployment window closed")
    arts = artifacts()
    dep = dependencies()["contracts"]
    g, t, v = p["governance"], p["token"], p["vault"]
    initializer = safe.cast_calldata("setup(address[],uint256,address,bytes,address,address,uint256,address)",
                                    "[" + ",".join(g["owners"]) + "]", str(g["threshold"]),
                                    ZERO, "0x", ZERO, ZERO, "0", ZERO)
    safe_init = bytes.fromhex(proof["proxyCreationCode"][2:]) + k.addr_word(dep["singleton"]["address"])
    safe_salt = k.keccak(k.keccak(initializer) + k.word(g["saltNonce"]))
    addresses = {"safe": create2(dep["proxyFactory"]["address"], safe_salt, k.keccak(safe_init))}
    transactions = [{"chainId": CHAIN, "from": p["deployer"], "to": dep["proxyFactory"]["address"], "value": "0x0",
                     "data": "0x" + safe.cast_calldata("createProxyWithNonce(address,bytes,uint256)",
                         dep["singleton"]["address"], "0x" + initializer.hex(), str(g["saltNonce"])).hex()}]
    contracts = {}
    for name, (project, _, target) in ARTIFACTS.items():
        args = b""
        if name == "token":
            init = safe.cast_calldata("initialize(string,string,uint256,address)", t["name"], t["symbol"],
                                      t["capWei"], addresses["safe"])
            args = abi("constructor(address,bytes)", addresses["implementation"], "0x" + init.hex())
        elif name == "vault":
            args = abi("constructor(address,address,uint256,uint256,uint256,uint256,uint256,bool,address)",
                       addresses["v1"], addresses["token"], v["depositDeadline"], v["commitDeadline"],
                       v["executionWindowSeconds"], 0, 10000, "true", addresses["safe"])
        creation = bytes.fromhex(arts[name]["bytecode"]["object"][2:])
        code = creation + args
        # Salt binds all approvals, including deployer, dates and quorum; no production salt is reused.
        salt = k.keccak(b"SUR-768/Base-Sepolia/" + name.encode() + bytes.fromhex(digest(p)))
        addresses[name] = create2(dep["create2Deployer"]["address"], salt, k.keccak(code))
        contracts[name] = {"initCode": "0x" + code.hex(), "initCodeHash": "0x" + k.keccak(code).hex(),
                           "salt": "0x" + salt.hex(), "constructorArguments": "0x" + args.hex(),
                           "creationHash": digest(arts[name]["bytecode"]), "abiHash": digest(arts[name]["abi"]),
                           "runtimeTemplateHash": digest(arts[name]["deployedBytecode"]),
                           "explorer": {"chainId": CHAIN, "project": project, "target": target,
                                        "compiler": "v0.8.28+commit.7893614a", "optimizerRuns": 200,
                                        "evmVersion": "cancun", "bytecodeHash": "none"}}
        transactions.append({"chainId": CHAIN, "from": p["deployer"], "to": dep["create2Deployer"]["address"],
                             "value": "0x0", "data": "0x" + (salt + code).hex()})
    inputs = sources()
    plan = {"schema": 1, "chainId": CHAIN, "kind": "unsigned-testnet-deployment", "params": p,
            "paramsHash": digest(p), "preflight": proof, "addresses": addresses, "contracts": contracts,
            "safeInitializer": "0x" + initializer.hex(), "transactions": transactions,
            "revision": k.run_tool(["git", "rev-parse", "HEAD"], k.PROJECT).strip(),
            "sourceHash": digest(inputs), "sources": inputs,
            "roleAssignments": {"vaultOwner": addresses["safe"], "tokenAllRoles": addresses["safe"],
                                "deployerPrivileges": "none", "fixtureMint": "public bounded faucet"}}
    return plan | {"planHash": digest(plan)}


def check_plan(plan, p):
    require(plan == make_plan(p, plan["preflight"], for_deployment=False), "stale/tampered deployment plan; regenerate and review")
    return plan


def simulate(plan, p, url):
    check_plan(plan, p)
    rpc = ReadRpc(url)
    require(rpc.chain_id() == CHAIN, "simulation RPC must be 84532")
    pin = plan["preflight"]["block"]
    require(block_id(rpc.block(pin["number"])) == pin, "simulation fork origin mismatch")
    for dep in dependencies()["contracts"].values():
        raw = rpc.call("eth_getCode", [dep["address"], hex(pin["number"])])
        require("0x" + k.keccak(bytes.fromhex(raw[2:])).hex() == dep["runtimeCodeHash"], "dependency code hash mismatch")
    for value in plan["addresses"].values():
        require(rpc.call("eth_getCode", [value, hex(pin["number"])]) == "0x", "simulation pin already has deployment")
    path = HERE / "output" / "simulation" / plan["planHash"] / "plan.json"
    save(path, plan)
    before_code = {name: rpc.call("eth_getCode", [target, "latest"]) for name, target in plan["addresses"].items()}
    before_nonce = rpc.call("eth_getTransactionCount", [p["deployer"], "latest"])
    trace = k.run_tool(["forge", "script", "script/SepoliaDryRun.s.sol:SepoliaDryRun", "--fork-url", url,
                        "--fork-block-number", str(pin["number"]), "-vvvv"], k.PROJECT,
                       env={"TESTNET_PLAN": str(path)}, timeout=180)
    output = json.loads(Path(str(path) + ".simulation.json").read_text())
    require(output.pop("planHash") == plan["planHash"] and set(output) == set(plan["addresses"]), "bad simulation output")
    # Compare live state as well as the historical fork pin: an old block alone cannot prove absence of writes.
    for name, target in plan["addresses"].items():
        require(rpc.call("eth_getCode", [target, "latest"]) == before_code[name], "source RPC code changed during simulation")
    require(rpc.call("eth_getTransactionCount", [p["deployer"], "latest"]) == before_nonce, "source deployer nonce changed")
    Path(str(path) + ".trace.txt").write_text(trace)
    return {"planHash": plan["planHash"], "chainId": CHAIN, "block": pin, "publicWrites": False,
            "method": "forge in-memory; no broadcast cheatcodes", "runtimeCode": output,
            "runtimeCodeHashes": {name: "0x" + k.keccak(bytes.fromhex(code[2:])).hex() for name, code in output.items()}}


def check_transition(action, s):
    require(s["active"] == 0 or action == "rotate", "claims activated: recovery permanently closed")
    if action == "commit-root":
        require(s["phase"] == 0 and s["depositDeadline"] < s["now"] <= s["commitDeadline"], "outside commit window")
    elif action == "activate":
        require(s["phase"] == 1 and s["now"] <= s["committedAt"] + s["executionWindow"], "activation ineligible")
        require(0 < s["total"] <= s["cap"] - s["supply"], "backing exceeds mint headroom")
    elif action == "cancel":
        require(s["phase"] == 0, "cancel requires Open, before commitment")
    elif action == "expire-commit":
        require(s["phase"] == 0 and s["now"] > s["commitDeadline"], "commit timeout ineligible")
    elif action == "expire-execution":
        require(s["phase"] == 1 and s["now"] > s["committedAt"] + s["executionWindow"], "execution timeout ineligible")
    elif action == "refund":
        require(s["phase"] == 2, "refund requires cancellation/timeout")
    else:
        require(action == "rotate", "unknown transition")


def build_tree(rows):
    rows = sorted(rows, key=lambda row: int(address(row[0]), 16))
    require(rows and len({row[0].lower() for row in rows}) == len(rows), "empty or duplicate allocation")
    for _, amount in rows:
        integer(amount, 1)
    leaves = [{"index": i, "account": account, "amount": str(amount), "proof": []}
              for i, (account, amount) in enumerate(rows)]
    levels = [[k.keccak(k.word(i) + bytes.fromhex(account[2:]) + k.word(amount))
               for i, (account, amount) in enumerate(rows)]]
    while len(levels[-1]) > 1:
        level = levels[-1]
        levels.append([k.keccak(min(level[j], level[j + 1]) + max(level[j], level[j + 1]))
                       if j + 1 < len(level) else level[j] for j in range(0, len(level), 2)])
    for i, leaf in enumerate(leaves):
        index = i
        for level in levels[:-1]:
            if (index ^ 1) < len(level):
                leaf["proof"].append("0x" + level[index ^ 1].hex())
            index //= 2
    return {"root": "0x" + levels[-1][0].hex(), "total": str(sum(x[1] for x in rows)),
            "leafCount": len(leaves), "leaves": leaves}


def readback(plan, p, rpc, expected, local=False, governance=None):
    require(rpc.chain_id() == CHAIN, "readback chain must be 84532")
    head = block_id(rpc.block())
    # Deployment approval expiry cannot disable a deployed vault's recovery or governance.
    validate(p, for_deployment=False)
    require(local or "anvil" not in rpc.call("web3_clientVersion", []).lower(), "local readback requires --local")
    a = plan["addresses"]
    for name, target in a.items():
        code = rpc.call("eth_getCode", [target, "latest"])
        require(code == expected["runtimeCode"][name], name + " runtime bytecode differs from fresh simulation")
    for name, dep in dependencies()["contracts"].items():
        require(safe.code_hash(rpc, dep["address"]) == dep["runtimeCodeHash"], name + " dependency code hash mismatch")
    slot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
    require(int(rpc.call("eth_getStorageAt", [a["token"], slot, "latest"]), 16) == int(a["implementation"], 16),
            "wrong ERC1967 implementation")
    require(int(rpc.call("eth_getStorageAt", [a["safe"], "0x0", "latest"]), 16)
            == int(dependencies()["contracts"]["singleton"]["address"], 16), "wrong Safe singleton")
    require(safe.text(rpc, a["safe"], "VERSION()") == "1.4.1", "wrong Safe version")
    raw = safe.view(rpc, a["safe"], "getOwners()")
    count = int.from_bytes(raw[32:64], "big")
    owners = [k.checksum("0x" + raw[64 + 32 * i + 12:96 + 32 * i].hex()) for i in range(count)]
    g = governance or p["governance"]
    require([x.lower() for x in owners] == [x.lower() for x in g["owners"]]
            and safe.uint(rpc, a["safe"], "getThreshold()") == g["threshold"], "wrong Safe owners/quorum")
    require(safe.view(rpc, a["safe"], "domainSeparator()") == safe.domain_separator(CHAIN, a["safe"]), "Safe domain mismatch")
    modules = safe.view(rpc, a["safe"], "getModulesPaginated(address,uint256)", k.word(1), k.word(20))
    require(int.from_bytes(modules[32:64], "big") == 1 and int.from_bytes(modules[64:96], "big") == 0,
            "Safe has modules or malformed module list")
    for preimage in (b"guard_manager.guard.address", b"fallback_manager.handler.address"):
        require(int(rpc.call("eth_getStorageAt", [a["safe"], "0x" + k.keccak(preimage).hex(), "latest"]), 16) == 0,
                "unexpected Safe guard/fallback handler")
    for name, want in (("name()", p["token"]["name"]), ("symbol()", p["token"]["symbol"])):
        require(safe.text(rpc, a["token"], name) == want, "wrong token metadata")
    for target in (a["v1"], a["token"]):
        require(safe.uint(rpc, target, "decimals()") == 18, "wrong decimals")
    require(safe.uint(rpc, a["token"], "CANONICAL_CHAIN_ID()") == CHAIN, "wrong token chain identity")
    require(safe.uint(rpc, a["token"], "cap()") == int(p["token"]["capWei"]), "wrong cap")
    roles = [bytes(32)] + [k.keccak(name) for name in (b"MINTER_ROLE", b"BURNER_ROLE", b"UPGRADER_ROLE")]
    for role in roles:
        require(safe.uint(rpc, a["token"], "hasRole(bytes32,address)", role, k.addr_word(a["safe"])) == 1, "Safe missing role")
        for account in [p["deployer"], *owners]:
            require(safe.uint(rpc, a["token"], "hasRole(bytes32,address)", role, k.addr_word(account)) == 0, "EOA retains token role")
    # Initialization grants only the Safe. Reject later unreviewed delegation, including unknown EOAs.
    topic = "0x" + k.keccak(b"RoleGranted(bytes32,address,address)").hex()
    # Chunked window: the public https://sepolia.base.org RPC rejects unbounded 500-block
    # eth_getLogs with HTTP 413 (Payload Too Large). 100-block chunks stay under the limit.
    for start in range(plan["preflight"]["block"]["number"], head["number"] + 1, 100):
        logs = rpc.call("eth_getLogs", [{"address": a["token"], "fromBlock": hex(start),
                        "toBlock": hex(min(start + 99, head["number"])), "topics": [topic]}])
        require(all(len(log["topics"]) == 4 and int(log["topics"][2], 16) == int(a["safe"], 16)
                    and not log.get("removed", False) for log in logs), "unreviewed token role grant")
    init = safe.cast_calldata("initialize(string,string,uint256,address)", p["token"]["name"], p["token"]["symbol"],
                              p["token"]["capWei"], a["safe"])
    reason = "0x" + safe.cast_calldata("Error(string)", "Initializable: contract is already initialized").hex()
    for target in (a["implementation"], a["token"]):
        reply = rpc._request("eth_call", [{"from": p["deployer"], "to": target, "data": "0x" + init.hex()}, "latest"])
        require(reply.get("error", {}).get("data") == reason, "initialization not demonstrably locked")
    for getter, want in (("owner()", a["safe"]), ("pendingOwner()", ZERO), ("V1()", a["v1"]), ("V2()", a["token"])):
        require(safe.address(rpc, a["vault"], getter).lower() == want.lower(), "vault wiring: " + getter)
    v = p["vault"]
    for getter, want in (("DEPOSIT_DEADLINE()", v["depositDeadline"]), ("COMMIT_DEADLINE()", v["commitDeadline"]),
                          ("EXECUTION_WINDOW()", v["executionWindowSeconds"]), ("CLAIM_PERIOD()", 0),
                          ("MIGRATION_RATE_BPS()", 10000), ("PRO_RATA_ENABLED()", 1)):
        require(safe.uint(rpc, a["vault"], getter) == want, "vault deal: " + getter)
    return {"planHash": plan["planHash"], "chainId": CHAIN, "block": head,
            "scope": "local-rehearsal" if local else "public-testnet",
            "addresses": a, "runtimeCodeHashes": expected["runtimeCodeHashes"],
            "owners": owners, "threshold": g["threshold"], "safeNonce": safe.uint(rpc, a["safe"], "nonce()"),
            "verified": True}


def verified_context(plan, p, url, local=False):
    # Recompute expected code from current compiler artifacts, never trust a supplied readback receipt.
    expected = simulate(plan, p, url)
    latest = ReadRpc(url)
    head = block_id(latest.block())
    rpc = ReadRpc(url, at=head["number"])
    report = readback(plan, p, rpc, expected, local)
    require(block_id(latest.block(head["number"])) == head, "readback head was reorged")
    return rpc, report


def snapshot_packet(plan, p, rpc, report, block, start, out):
    a = plan["addresses"]
    local = report["scope"] == "local-rehearsal"
    head = block_id(rpc.block(block))
    snapshots.check_block(rpc, block, head["hash"], rehearsal=local)
    require(head["timestamp"] > p["vault"]["depositDeadline"], "ledger is not frozen")
    require(snapshots.call_uint(rpc, a["vault"], k.selector("phase()"), block) == 0, "snapshot must precede commitment")
    accounts = snapshots.depositors(rpc, a["vault"], start, block, 10)
    rows = []
    for account in accounts:
        net = snapshots.call_uint(rpc, a["vault"], k.selector("credited(address)") + k.addr_word(account), block)
        net -= snapshots.call_uint(rpc, a["vault"], k.selector("withdrawn(address)") + k.addr_word(account), block)
        require(net >= 0, "negative ledger")
        if net:
            rows.append((account, net))
    tree = build_tree(rows)
    out = Path(out)
    save(out / "tree.json", tree)
    verified = snapshots.verify_tree_py(out / "tree.json", rpc, a["vault"], block, 10000)
    data = {"planHash": plan["planHash"], "chainId": CHAIN, "vault": a["vault"], "block": block,
            "blockHash": head["hash"], "blockTimestamp": head["timestamp"], "rateBps": 10000,
            "root": tree["root"], "totalClaimable": tree["total"], "leaves": tree["leafCount"],
            "netLedgerV1": verified["netLedgerV1"], "scannedFromBlock": start,
            "sha256": {"tree.json": k.sha256_file(out / "tree.json")}, "scope": report["scope"]}
    save(out / "snapshot.json", data)
    snapshots.verify_snapshot(out / "tree.json", rpc, a["vault"], p, rehearsal=local)
    return data


def transaction_packet(action, plan, p, rpc, report, nonce=None, tree=None, account=None, old_owner=None, new_owner=None):
    a, v = plan["addresses"], p["vault"]
    read = lambda getter: safe.uint(rpc, a["vault"], getter)
    state = {"phase": read("phase()"), "active": read("claimsEverActive()"), "now": report["block"]["timestamp"],
             "depositDeadline": v["depositDeadline"], "commitDeadline": v["commitDeadline"],
             "committedAt": read("rootCommittedAt()"), "executionWindow": v["executionWindowSeconds"],
             "total": read("totalClaimable()"), "supply": safe.uint(rpc, a["token"], "totalSupply()"),
             "cap": int(p["token"]["capWei"])}
    check_transition(action, state)
    snapshot_hash = None
    calls = []
    rotation = None
    if action in ("commit-root", "activate"):
        if tree is None:
            raise ValueError("both commit and activation require the frozen snapshot/tree")
        snapshot = snapshots.verify_snapshot(Path(tree), rpc, a["vault"], p, rehearsal=report["scope"] == "local-rehearsal")
        require(snapshot.get("planHash") == plan["planHash"], "mixed snapshot/deployment")
        snapshot_hash = k.sha256_file(Path(tree).parent / "snapshot.json")
        root = bytes.fromhex(snapshot["root"][2:])
        total = int(snapshot["totalClaimable"])
        if action == "commit-root":
            require(safe.view(rpc, a["vault"], "root()") == bytes(32), "already committed")
            data = safe.encode("commitRoot(bytes32,uint256)", root, k.word(total))
            calls = [{"to": a["vault"], "data": data}]
        else:
            require(safe.view(rpc, a["vault"], "root()") == root and state["total"] == total, "on-chain commitment differs from snapshot")
            require(safe.balance(rpc, a["token"], a["vault"]) == 0, "already funded; review rather than mint twice")
            calls = [{"to": a["token"], "data": safe.encode("mint(address,uint256)", k.addr_word(a["vault"]), k.word(total))},
                     {"to": a["vault"], "data": safe.encode("activateClaims()") }]
    elif action == "rotate":
        old_owner = address(old_owner)
        new_owner = address(new_owner)
        owners = report["owners"]
        require(old_owner.lower() in [x.lower() for x in owners], "old owner not in Safe")
        require(new_owner.lower() not in {x.lower() for x in [*owners, a["safe"], p["deployer"]]}, "invalid replacement owner")
        index = [x.lower() for x in owners].index(old_owner.lower())
        previous = owners[index - 1] if index else "0x" + "0" * 39 + "1"
        calls = [{"to": a["safe"], "data": safe.encode("swapOwner(address,address,address)",
                  k.addr_word(previous), k.addr_word(old_owner), k.addr_word(new_owner))}]
        rotation = {"oldOwner": old_owner, "newOwner": new_owner,
                    "ownersAfter": owners[:index] + [new_owner] + owners[index + 1:], "thresholdAfter": report["threshold"]}
    elif action == "refund":
        account = address(account)
        require(safe.uint(rpc, a["vault"], "availableToWithdraw(address)", k.addr_word(account)) > 0, "no refundable ledger credit")
        calls = [{"to": a["vault"], "data": safe.encode("refund(address)", k.addr_word(account))}]
    else:
        signature = {"cancel": "cancel()", "expire-commit": "expireCommit()", "expire-execution": "expireExecution()"}[action]
        calls = [{"to": a["vault"], "data": safe.encode(signature)}]
    packet = {"schema": 1, "action": action, "chainId": CHAIN, "scope": report["scope"], "planHash": plan["planHash"],
              "paramsHash": plan["paramsHash"], "sourceHash": plan["sourceHash"], "snapshotHash": snapshot_hash,
              "block": report["block"], "addresses": a, "rotation": rotation,
              "calls": [{"to": call["to"], "value": "0", "data": "0x" + call["data"].hex()} for call in calls]}
    if action in ("expire-commit", "expire-execution", "refund"):
        require(nonce is None, "permissionless holder call, not a Safe transaction")
        packet["transaction"] = {"chainId": CHAIN, "to": calls[0]["to"], "value": "0x0", "data": "0x" + calls[0]["data"].hex()}
    else:
        nonce = integer(nonce)
        require(nonce == report["safeNonce"], "Safe nonce mismatch")
        tx = safe.safe_tx(dependencies()["contracts"]["multiSendCallOnly"]["address"], safe.multisend_data(calls), 1, nonce) if len(calls) > 1 else safe.safe_tx(calls[0]["to"], calls[0]["data"], 0, nonce)
        packet["safeTxHash"] = "0x" + safe.safe_tx_hash(rpc, CHAIN, a["safe"], tx).hex()
        packet["safeTransaction"] = dict(tx, data="0x" + tx["data"].hex())
        packet["builder"] = {"version": "1.0", "chainId": str(CHAIN), "createdAt": 0,
                             "meta": {"name": "TESTNET ONLY: " + action, "createdFromSafeAddress": a["safe"],
                                      "description": "Require exact Safe nonce/hash/gas/operation from companion packet; unsigned",
                                      "txBuilderVersion": safe.TX_BUILDER_VERSION, "checksum": ""},
                             "transactions": [dict(call, contractMethod=None, contractInputsValues=None) for call in packet["calls"]]}
    return packet | {"packetHash": digest(packet)}


def check_packet(packet, plan, p, rpc, report, tree=None):
    require(packet["packetHash"] == digest({key: value for key, value in packet.items() if key != "packetHash"}), "packet hash mismatch")
    require(block_id(rpc.block(packet["block"]["number"])) == packet["block"], "packet block is noncanonical")
    rotation = packet["rotation"] or {}
    account = "0x" + packet["calls"][0]["data"][-40:] if packet["action"] == "refund" else None
    fresh = transaction_packet(packet["action"], plan, p, rpc, report,
                               nonce=packet.get("safeTransaction", {}).get("nonce"), tree=tree, account=account,
                               old_owner=rotation.get("oldOwner"), new_owner=rotation.get("newOwner"))
    omit = ("packetHash", "block")
    require({key: value for key, value in fresh.items() if key not in omit}
            == {key: value for key, value in packet.items() if key not in omit}, "stale/mixed packet")
    return {"packetHash": packet["packetHash"], "verifiedAt": report["block"], "verified": True}


def web_config(plan, p, rpc, report, web_rpc, local=False):
    parsed = urlsplit(web_rpc)
    require(not parsed.username and not parsed.password and not parsed.query and not parsed.fragment,
            "only publishable RPC URLs, no credentials")
    if local:
        k.require_loopback(web_rpc)
        require(report["scope"] == "local-rehearsal", "local config needs local evidence")
    else:
        require(parsed.scheme == "https" and parsed.hostname == "sepolia.base.org" and parsed.path in ("", "/")
                and parsed.port is None and report["scope"] == "public-testnet", "public config needs official public RPC and public readback")
    a = plan["addresses"]
    first = snapshots.deploy_block(rpc, a["vault"], report["block"]["number"])
    raw = {"enabled": "false", "mode": "testnet-rehearsal" if local else "testnet", "rpcUrl": web_rpc,
           "v1": a["v1"], "v2": a["token"], "vault": a["vault"], "vaultCodeHash": report["runtimeCodeHashes"]["vault"],
           "depositOpen": str(block_id(rpc.block(first))["timestamp"]), "walletConnectProjectId": ""}
    names = {"enabled": "ENABLED", "mode": "MODE", "rpcUrl": "RPC_URL", "v1": "V1", "v2": "V2",
             "vault": "VAULT", "vaultCodeHash": "VAULT_CODE_HASH", "depositOpen": "DEPOSIT_OPEN"}
    return {"planHash": plan["planHash"], "chainId": CHAIN, "scope": report["scope"], "raw": raw,
            "env": {"NEXT_PUBLIC_TOKEN_MIGRATION_" + names[key]: raw[key] for key in names},
            "warning": "Disabled by default. Publish only after Bill approval and wallet acceptance. Test assets have no value."}


def planned_config(plan, simulation):
    a = plan["addresses"]
    return {"planHash": plan["planHash"], "chainId": CHAIN, "scope": "public-plan-not-deployed",
            "raw": {"enabled": "false", "mode": "testnet", "rpcUrl": "https://sepolia.base.org",
                    "v1": a["v1"], "v2": a["token"], "vault": a["vault"],
                    "vaultCodeHash": simulation["runtimeCodeHashes"]["vault"], "depositOpen": "TBD",
                    "walletConnectProjectId": ""},
            "warning": "Predicted addresses only, no deployment. Cannot enable: depositOpen is TBD. Replace with verified config after separate approval."}


def explorer_inputs():
    result = {}
    for name, (project, _, target) in ARTIFACTS.items():
        raw = k.run_tool(["forge", "verify-contract", "0x" + "0" * 39 + "2", target,
                          "--chain", str(CHAIN), "--show-standard-json-input"], k.CONTRACTS / project)
        result[name] = json.loads(raw)
    return result


def execution_success(log, safe_address, tx_hash):
    return (log.get("address", "").lower() == safe_address.lower() and log.get("removed") is False
            and log.get("topics") == [safe.EXECUTION_SUCCESS, tx_hash] and log.get("data") == "0x" + "00" * 32)


def verify_rotation(plan, p, url, packet, local=False):
    require(packet["action"] == "rotate", "not a signer rotation packet")
    expected = simulate(plan, p, url)
    historical = ReadRpc(url, at=packet["block"]["number"])
    before = readback(plan, p, historical, expected, local)
    check_packet(packet, plan, p, historical, before)
    current = ReadRpc(url)
    head = block_id(current.block())
    rpc = ReadRpc(url, at=head["number"])
    rotation = packet["rotation"]
    governance = {"owners": rotation["ownersAfter"], "threshold": rotation["thresholdAfter"]}
    after = readback(plan, p, rpc, expected, local, governance)
    require(after["safeNonce"] == packet["safeTransaction"]["nonce"] + 1, "rotation nonce not advanced exactly once")
    logs = rpc.call("eth_getLogs", [{"address": plan["addresses"]["safe"],
                      "fromBlock": hex(packet["block"]["number"]), "toBlock": hex(head["number"]),
                      "topics": [safe.EXECUTION_SUCCESS]}])
    matched = [log for log in logs if execution_success(log, plan["addresses"]["safe"], packet["safeTxHash"])]
    require(len(matched) == 1, "missing or duplicate rotation ExecutionSuccess")
    receipt = rpc.call("eth_getTransactionReceipt", [matched[0]["transactionHash"]])
    require(receipt and receipt["status"] == "0x1" and receipt["to"].lower() == plan["addresses"]["safe"].lower(), "rotation receipt failed")
    return after | {"rotationPacketHash": packet["packetHash"], "receipt": receipt}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    command = sub.add_parser("validate", help="validate explicit, TBD-free testnet decisions")
    command.add_argument("--params", type=Path, required=True)
    command = sub.add_parser("preflight", help="read-only official dependency hashes at a safe/finalized pin")
    command.add_argument("--params", type=Path, required=True)
    command.add_argument("--rpc", required=True)
    command.add_argument("--tag", choices=("safe", "finalized"), default="finalized")
    command.add_argument("--out", type=Path, required=True)
    command = sub.add_parser("plan", help="deterministic unsigned Safe + CREATE2 deployments")
    command.add_argument("--params", type=Path, required=True)
    command.add_argument("--preflight", type=Path, required=True)
    command.add_argument("--out", type=Path, required=True)
    command = sub.add_parser("simulate", help="in-memory Foundry fork execution; never broadcast")
    command.add_argument("--params", type=Path, required=True)
    command.add_argument("--plan", type=Path, required=True)
    command.add_argument("--rpc", required=True)
    command.add_argument("--out", type=Path, required=True)
    command = sub.add_parser("config-plan", help="disabled public config with predicted addresses; not a deployment receipt")
    command.add_argument("--params", type=Path, required=True)
    command.add_argument("--plan", type=Path, required=True)
    command.add_argument("--rpc", required=True)
    command.add_argument("--out", type=Path, required=True)
    command = sub.add_parser("explorer", help="emit Standard JSON compiler inputs, never submit verification")
    command.add_argument("--params", type=Path, required=True)
    command.add_argument("--plan", type=Path, required=True)
    command.add_argument("--out", type=Path, required=True)
    for name in ("verify", "config", "snapshot", "packet", "check-packet", "verify-rotation"):
        command = sub.add_parser(name)
        command.add_argument("--params", type=Path, required=True)
        command.add_argument("--plan", type=Path, required=True)
        command.add_argument("--rpc", required=True)
        command.add_argument("--local", action="store_true", help="explicitly label loopback Anvil evidence, never public finality")
        command.add_argument("--out", type=Path, required=True)
        if name == "config":
            command.add_argument("--web-rpc", required=True)
        if name == "snapshot":
            command.add_argument("--block", type=int, required=True)
            command.add_argument("--from-block", type=int, required=True)
        if name == "packet":
            command.add_argument("--action", choices=("commit-root", "activate", "cancel", "expire-commit", "expire-execution", "refund", "rotate"), required=True)
            command.add_argument("--safe-nonce", type=int)
            command.add_argument("--account")
            command.add_argument("--old-owner")
            command.add_argument("--new-owner")
        if name in ("packet", "check-packet"):
            command.add_argument("--tree", type=Path)
        if name in ("check-packet", "verify-rotation"):
            command.add_argument("--packet", type=Path, required=True)
    args = parser.parse_args()
    p = json.loads(args.params.read_text())
    if args.command == "validate":
        validate(p)
    elif args.command == "preflight":
        save(args.out, preflight(p, ReadRpc(args.rpc), args.tag))
    elif args.command == "plan":
        save(args.out, make_plan(p, json.loads(args.preflight.read_text())))
    elif args.command == "simulate":
        save(args.out, simulate(json.loads(args.plan.read_text()), p, args.rpc))
    elif args.command == "config-plan":
        plan = json.loads(args.plan.read_text())
        require("anvil" not in ReadRpc(args.rpc).call("web3_clientVersion", []).lower(), "planned public config requires canonical RPC")
        save(args.out, planned_config(plan, simulate(plan, p, args.rpc)))
    elif args.command == "explorer":
        plan = check_plan(json.loads(args.plan.read_text()), p)
        for name, value in explorer_inputs().items():
            save(args.out / (name + ".standard-input.json"), value)
        save(args.out / "verification.json", {"planHash": plan["planHash"], "addresses": plan["addresses"],
                                               "contracts": plan["contracts"]})
    else:
        if args.local:
            k.require_loopback(args.rpc)
            require("anvil" in ReadRpc(args.rpc).call("web3_clientVersion", []).lower(), "--local requires Anvil")
        plan = json.loads(args.plan.read_text())
        if args.command == "verify-rotation":
            save(args.out, verify_rotation(plan, p, args.rpc, json.loads(args.packet.read_text()), args.local))
            print("OK: rotation read back against historical packet and ExecutionSuccess receipt")
            return
        rpc, report = verified_context(plan, p, args.rpc, args.local)
        if args.command == "verify":
            result = report
        elif args.command == "config":
            result = web_config(plan, p, rpc, report, args.web_rpc, args.local)
        elif args.command == "snapshot":
            result = snapshot_packet(plan, p, rpc, report, args.block, args.from_block, args.out)
        elif args.command == "packet":
            result = transaction_packet(args.action, plan, p, rpc, report, args.safe_nonce, args.tree,
                                        args.account, args.old_owner, args.new_owner)
        else:
            result = check_packet(json.loads(args.packet.read_text()), plan, p, rpc, report, args.tree)
        if args.command != "snapshot":
            save(args.out, result)
            if args.command == "packet" and "builder" in result:
                save(args.out.with_suffix(".builder.json"), result["builder"])
    print("OK: " + args.command + "; unsigned testnet preparation, no public writes")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError) as error:
        sys.exit("TESTNET STOP: " + k.scrub(str(error)))
