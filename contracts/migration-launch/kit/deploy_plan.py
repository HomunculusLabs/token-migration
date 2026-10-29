#!/usr/bin/env python3.14
"""Launch kit, phase "deploy-plan": every address, init-code hash and verification input for the launch's
deployments, then a dry run of all of them on a fork. Nothing is broadcast.

    python3.14 kit/deploy_plan.py --rpc <fork RPC> [--params kit/params.json | --rehearsal]
                                  [--hook-artifact <forge artifact of the fee hook>]

Deploy order (each step needs the address of the one before): the Safe (SafeProxyFactory CREATE2 over its
setup data) → the v2 implementation → the v2 ERC1967 proxy, initialized in its constructor with the Safe as
governance → the vault (owner = the Safe) → the settler (pinned to the Safe, v2, the old pool and the
successor fee and spacing) → the hook (initializer = the settler, salt mined for the 0x2044 flags). All but
the Safe go through the canonical CREATE2 deployer, so each address depends only on its init code and salt.

Outputs in kit/output/deploy/: resolved.json (the params this phase used, with no TBD), plan.json (addresses,
init code and hashes, constructor args, the hook salt), basescan.json (per-contract verification inputs),
dry-run.txt. The plan is cross-checked by an independent Python CREATE2 computation.
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kitlib as k  # noqa: E402

OUT = k.OUTPUT / "deploy"
HOOK_PROJECT = k.CONTRACTS / "fee-hook"
HOOK_ARTIFACT = HOOK_PROJECT / "out" / "SurplusFeeHook.sol" / "SurplusFeeHook.json"
STAND_IN_ARTIFACT = k.PROJECT / "out" / "HookStandIn.sol" / "HookStandIn.json"

# Every params key this phase reads. need() stops on any TBD among them and names the decision.
NEEDED = (
    "governance.owners", "governance.threshold", "governance.saltNonce",
    "token.name", "token.symbol", "token.capWei",
    "vault.depositDeadline", "vault.commitDeadline", "vault.executionWindowSeconds", "vault.claimPeriodSeconds",
    "vault.rateBps", "vault.proRata", "hook.feeRecipient", "operators.deployer",
)


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Launch kit deploy plan: predicted addresses + fork dry run.")
    ap.add_argument("--rpc")
    ap.add_argument("--params")
    ap.add_argument("--rehearsal", action="store_true")
    ap.add_argument("--hook-artifact", type=Path)
    return ap.parse_args()


def resolve(params: dict, rehearsal: bool, hook_artifact: Path | None) -> dict:
    k.need(params, *NEEDED)
    ext = params["external"]
    governance = params["governance"]
    if governance.get("existingSafe"):
        k.fail("governance.existingSafe is set: this phase plans a NEW Safe; drop existingSafe or plan by hand")
    fee_recipient = params["hook"]["feeRecipient"]
    artifact = hook_artifact or (HOOK_ARTIFACT if HOOK_ARTIFACT.is_file() else None)
    if artifact is None:
        # No stand-in fallback, not even for a rehearsal: the settler refuses a successor hook that does not charge
        # the 1.5% fee to the decided recipient, so a plan built on HookStandIn could never launch.
        k.fail(f"no fee-hook artifact at {HOOK_ARTIFACT}: build contracts/fee-hook first")
    hook_code = json.loads(artifact.read_text())["bytecode"]["object"]
    resolved = {
        "chainId": params["chainId"],
        "create2Deployer": ext["create2Deployer"],
        "safe141": ext["safe141"],
        "v1": ext["v1"], "weth": ext["weth"], "poolManager": ext["poolManager"],
        "positionManager": ext["positionManager"], "permit2": ext["permit2"], "v3Tail": ext["v3Tail"],
        "oldPool": ext["oldPool"],
        "governance": {"owners": [k.checksum(o) for o in governance["owners"]],
                       "threshold": governance["threshold"], "saltNonce": int(str(governance["saltNonce"]), 0)},
        "token": {"name": params["token"]["name"], "symbol": params["token"]["symbol"],
                  "capWei": int(params["token"]["capWei"])},
        "vault": {key: params["vault"][key] for key in ("depositDeadline", "commitDeadline",
                                                         "executionWindowSeconds", "claimPeriodSeconds",
                                                         "rateBps", "proRata")},
        "successorPool": params["successorPool"],
        "hook": {"feeRecipient": fee_recipient, "creationCode": hook_code,
                 "artifact": str(artifact.relative_to(k.CONTRACTS)), "standIn": artifact == STAND_IN_ARTIFACT},
        "salts": params["salts"],
        "operators": {"deployer": k.checksum(params["operators"]["deployer"])},
    }
    if fee_recipient == "safe":
        resolved["hook"]["feeRecipient"] = "0x" + "00" * 20  # filled with the planned Safe below
    return resolved


def create2(deployer: str, salt: bytes, init_hash: bytes) -> str:
    return k.checksum("0x" + k.keccak(b"\xff" + bytes.fromhex(deployer[2:]) + salt + init_hash)[12:].hex())


def cross_check(resolved: dict, plan: dict, factory_code: str) -> list[str]:
    """Recomputes every CREATE2 address in Python from the plan's init code: a second, independent
    derivation of the same addresses (Safe salt rule included)."""
    lines = []
    d = resolved["create2Deployer"]
    for key, init_key, salt in (("tokenImplementation", "tokenImplementationInitCode", resolved["salts"]["tokenImplementation"]),
                                ("token", "tokenProxyInitCode", resolved["salts"]["tokenProxy"]),
                                ("vault", "vaultInitCode", resolved["salts"]["vault"]),
                                ("settler", "settlerInitCode", resolved["salts"]["settler"]),
                                ("hook", "hookInitCode", plan["hookSalt"])):
        init = bytes.fromhex(plan[init_key][2:])
        got = create2(d, bytes.fromhex(salt[2:]), k.keccak(init))
        if got.lower() != plan[key].lower():
            k.fail(f"python CREATE2 for {key}: {got} != plan {plan[key]}")
        lines.append(f"{key:20} {got}  (python CREATE2 matches)")
    initializer = bytes.fromhex(plan["safeInitializer"][2:])
    salt = k.keccak(k.keccak(initializer) + k.word(resolved["governance"]["saltNonce"]))
    proxy_init = bytes.fromhex(factory_code[2:]) + k.addr_word(resolved["safe141"]["singleton"])
    got = create2(resolved["safe141"]["proxyFactory"], salt, k.keccak(proxy_init))
    if got.lower() != plan["safe"].lower():
        k.fail(f"python CREATE2 for the Safe: {got} != plan {plan['safe']}")
    lines.append(f"{'safe':20} {got}  (python CREATE2 matches)")
    hook = int(plan["hook"], 16)
    if hook & 0x3FFF != 0x2044:
        k.fail(f"hook {plan['hook']} does not carry exactly the 0x2044 flags")
    lines.append(f"{'hook flags':20} {hex(hook & 0x3FFF)} (exactly BEFORE_INITIALIZE | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA)")
    return lines


def basescan(plan: dict, resolved: dict) -> dict:
    """What `forge verify-contract` needs per contract. solc/optimizer settings come from each project's
    pinned foundry.toml (0.8.28, cancun, 200 runs, bytecode_hash none)."""
    def entry(project: str, target: str, address: str, args: str | None) -> dict:
        cmd = f"cd contracts/{project} && forge verify-contract {address} {target} --chain 8453 --watch"
        if args and args != "0x":
            cmd += f" --constructor-args {args}"
        return {"project": f"contracts/{project}", "contract": target, "address": address,
                "constructorArgs": args or "0x", "command": cmd}

    hook_project = "fee-hook" if not resolved["hook"]["standIn"] else "migration-launch (rehearsal stand-in)"
    return {
        "compiler": {"solc": "0.8.28", "evmVersion": "cancun", "optimizerRuns": 200, "bytecodeHash": "none"},
        "note": "Standard JSON input for any of these: forge verify-contract … --show-standard-json-input.",
        "contracts": [
            entry("token-v2", "src/SurplusTokenV2.sol:SurplusTokenV2", plan["tokenImplementation"], None),
            entry("token-v2", "../../node_modules/@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy",
                  plan["token"], plan["tokenProxyConstructorArgs"]),
            entry("migration", "src/MigrationVault.sol:MigrationVault", plan["vault"], plan["vaultConstructorArgs"]),
            entry("migration-launch", "src/MigrationSettler.sol:MigrationSettler", plan["settler"],
                  plan["settlerConstructorArgs"]),
            {**entry("fee-hook", "src/SurplusFeeHook.sol:SurplusFeeHook", plan["hook"], plan["hookConstructorArgs"]),
             "project": hook_project},
        ],
        "safe": {"address": plan["safe"], "note": "A standard Safe 1.4.1 proxy; Basescan verifies it as a proxy."},
    }


def run_plan(resolved: dict, rpc_url: str) -> dict:
    k.write_json(OUT / "resolved.json", resolved)
    k.run_tool(["forge", "script", "script/DeployPlan.s.sol", "--tc", "DeployPlan", "--fork-url", rpc_url],
               k.PROJECT, timeout=590)
    return json.loads((OUT / "plan.json").read_text())


def main() -> None:
    args = parse_args()
    params = k.load_phase_params(args.params, rehearsal=args.rehearsal)
    rpc_url = k.rpc_url(args.rpc)
    rpc = k.Rpc(rpc_url)
    if rpc.chain_id() != params["chainId"]:
        k.fail(f"RPC chainId {rpc.chain_id()} != params.chainId {params['chainId']}")

    k.run_tool(["forge", "build", "--deny", "warnings"], k.PROJECT, timeout=590)
    resolved = resolve(params, args.rehearsal, args.hook_artifact)
    OUT.mkdir(parents=True, exist_ok=True)
    fee_is_safe = params["hook"]["feeRecipient"] == "safe"

    # The Safe's address does not depend on the hook, so when the fee recipient is "the Safe" the first
    # plan gives its address and the second plan is final.
    plan = run_plan(resolved, rpc_url)
    if fee_is_safe:
        resolved["hook"]["feeRecipient"] = k.checksum(plan["safe"])
        plan = run_plan(resolved, rpc_url)
    factory_code = rpc.eth_call(resolved["safe141"]["proxyFactory"], "0x" + k.selector("proxyCreationCode()").hex())
    factory_code = "0x" + factory_code[2 + 128:2 + 128 + 2 * int(factory_code[66:130], 16)]
    lines = cross_check(resolved, plan, factory_code)

    dry = k.run_tool(["forge", "script", "script/DeployDryRun.s.sol", "--tc", "DeployDryRun", "--fork-url", rpc_url],
                     k.PROJECT, timeout=590)
    if "Script ran successfully" not in dry:
        k.fail("deploy dry run did not complete")
    k.write_json(OUT / "basescan.json", basescan(plan, resolved))
    summary = {
        "chainId": resolved["chainId"],
        "forkBlock": int(rpc.block()["number"], 16),
        "addresses": {key: plan[key] for key in ("safe", "tokenImplementation", "token", "vault", "settler", "hook")},
        "initCodeHashes": {key: plan[key] for key in ("tokenImplementationInitCodeHash", "tokenProxyInitCodeHash",
                                                       "vaultInitCodeHash", "settlerInitCodeHash", "hookInitCodeHash")},
        "hookSalt": plan["hookSalt"],
        "hookStandIn": resolved["hook"]["standIn"],
    }
    k.write_json(OUT / "deployment.json", {key: plan[key] for key in ("safe", "token", "vault", "settler", "hook")}
                 | {"v2": plan["token"]})
    (OUT / "dry-run.txt").write_text("\n".join(lines) + "\nDeployDryRun: every deployment landed at its predicted "
                                     "address with the decided settings\n")
    k.write_json(OUT / "summary.json", summary)
    print("\n".join(lines))
    print("DeployDryRun: every deployment landed at its predicted address with the decided settings")
    if resolved["hook"]["standIn"]:
        print("NOTE: the hook is the rehearsal stand-in (contracts/fee-hook not built here); --rehearsal only")
    print(f"wrote {OUT.relative_to(k.PROJECT)}/{{resolved,plan,basescan,deployment,summary}}.json + dry-run.txt")


if __name__ == "__main__":
    main()
