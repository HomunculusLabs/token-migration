# Base Sepolia preparation — unsigned, test assets only

This directory is isolated from the production launch kit. It does not call the production
phase CLIs, change `kitlib.OUTPUT`, write the production manifest, sign, or send a public-chain
transaction. `prepare.py` uses an RPC method allowlist. Its `simulate` command runs Foundry's
EVM **in memory**, without broadcast cheatcodes. `rehearse.py` alone sends transactions, to an
Anvil process it starts on a new numeric loopback port and always terminates.

**This is preparation, not deployment approval or human-wallet acceptance.** Bill must choose
the real testnet owners, threshold, deployer and dates. `params.json` deliberately keeps those
values `TBD`. No wallet/environment file is read; no private-key, mnemonic, signing, broadcast,
or execute option exists. The rehearsal needs no private keys: deterministic, test-only actor
addresses authorize real Safe `approveHash` calls through local impersonation.

## What is deployed in simulation

1. Official **SafeL2 1.4.1**, initialized atomically through its official proxy factory. L2, because
   Safe's hosted transaction service and wallet only index L2 singletons on Base; a plain-singleton
   Safe shows as an unsupported version and its executed transactions never reach the app's history.
   No modules, guard, fallback handler, payment or setup delegatecall. Explicit owners and quorum.
2. `TestnetV1`: 18 decimals, `TEST ONLY Surplus V1` / `TEST-V1`. Anyone can faucet up to
   1,000 tokens per call, with a hard 1,000,000-token lifetime supply cap. No premint, burn,
   owner, or privileged faucet. It deploys only on chain **84532**. Anyone can exhaust the
   fixture; deploy a fresh exercise instead of treating it as a real asset or faucet service.
3. `SurplusTokenV2BaseSepolia`, mechanically generated from the unchanged production token,
   with only the contract declaration's name and chain constant changed. Its implementation
   is initialization-locked; its ERC1967 proxy initializes once in its constructor. The Safe
   receives admin, minter, burner and upgrader; the deployer and individual signers receive none.
4. The **unchanged** `MigrationVault`, owned by the Safe from construction, using 1:1 pro-rata
   claims with no expiry. Claims activate via exactly two calls: mint backing to the vault,
   then `activateClaims()`. There is **no sell, hook, pool, settler, LP position, or production
   economics simulation**. Fixture V1 stays in the vault on the successful path.

All addresses are deterministic: the Safe's factory CREATE2 uses its complete initializer;
other contracts use the verified deterministic-deployment proxy, their complete init code,
and salts bound to every parameter. Any owner/order/quorum, dates, deployer or artifact change
requires a new plan and review. Deployer funding, transaction nonces and gas pricing are NOT
assumed by the unsigned deployment skeletons: an approved operator must review those at
execution time. The Safe packets, in contrast, bind the exact current Safe nonce and all gas,
operation and refund fields. An occupied original simulation pin is rejected; a partial current deployment fails
readback. There is no automatic resume/redeploy or hidden initialization step.

## Pinned dependency provenance

`dependencies.json` pins the canonical 84532 addresses and runtime Keccak hashes from
[safe-global/safe-deployments, revision 7b1fb6d615ab2d2999550ec9166554b180e813e5](https://github.com/safe-global/safe-deployments/tree/7b1fb6d615ab2d2999550ec9166554b180e813e5/src/assets/v1.4.1).
The proxy creation code is read from the hash-verified factory's `proxyCreationCode()`.
The CREATE2 deployer's full runtime is extracted from the published deployment transaction in
[Arachnid/deterministic-deployment-proxy, revision be3c5974db5028d502537209329ff2e730ed336c](https://github.com/Arachnid/deterministic-deployment-proxy/blob/be3c5974db5028d502537209329ff2e730ed336c/README.md).

Every preflight checks `eth_chainId == 84532`, rejects Anvil masquerading as public finality,
pins `finalized` (or explicitly `safe`), verifies every dependency hash and rechecks the block
identity. The local write guard independently checks the upstream chain, exact fork block and
hash, Anvil fork configuration and every dependency **before the first write**. A mainnet fork
with a replaced chain ID is not a Sepolia rehearsal. Missing RPC/archive state is a blocker,
not a reason to substitute fabricated receipts.

## Requirements and decisions

Use the repository's existing Python 3.14, Foundry 1.7.1 / Solidity 0.8.28, and npm-pinned
OpenZeppelin packages. No new dependency, submodule, service, or root manifest is needed.
Run commands below from `contracts/migration-launch`. Use a fresh `kit/testnet/output/<run>`
(or an external scratch directory). Outputs are immutable: a differing existing file is rejected.
Never point this tooling at `kit/output` or a production manifest. The Foundry fs permission
adds only `kit/testnet/output` to the existing allowed paths.

Fill a copy of `params.json` with decisions, never edit the production params:

| Field | Owner / constraint |
|---|---|
| `deployer` | Bill; exact nonzero EOA address, not a governance signer |
| `governance.owners` | Bill; 2–20 unique, validated addresses in the approved order |
| `governance.threshold` | Bill; explicit integer, 2 through owner count; no single-key governance |
| `governance.saltNonce` | Bill/operator; explicit uint256, new exercise identity |
| `vault.depositDeadline`, `vault.commitDeadline` | Bill/operator; Unix seconds, strict increasing order |
| `vault.executionWindowSeconds` | Bill/operator; 1–86,400 seconds for the test exercise |
| `validUntil` | Bill/operator; new-deployment approval expiry within seven days of the canonical preflight pin and current preparation time, covering commit + execution window |

Test metadata, 1,000,000-token cap, 1:1 rate, pro-rata enabled and zero claim period are fixtures,
not proposed production decisions. These values are validated, not silently defaulted. Invalid
mixed-case checksums, whitespace, duplicate owners, numeric booleans, unknown fields, expired
deployment approvals and wrong modes/chains are rejected. After deployment, the same immutable
params remain valid for identity/readback, recovery and governance; `validUntil` is not a holder
refund or claim deadline. Contract phase/deadline checks still govern every packet. Do not paste
credentials into params or commands.
Plan revalidation always retains the seven-day bound against the original preflight pin, even
after wall-clock expiry; a fresh deployment plan also requires a live approval window.

## CLI runbook

Below, `P` is the filled, approved copy; `O` is a **new** output directory; `RPC` is a canonical,
read-only Base Sepolia archive RPC (the official public endpoint is `https://sepolia.base.org`).
Shell variables are placeholders, not defaults or approval. The committed TBD file is expected
to fail `validate` until Bill supplies decisions.

```bash
python3.14 -B kit/testnet/prepare.py validate --params "$P"
python3.14 -B kit/testnet/prepare.py preflight --params "$P" --rpc "$RPC" --out "$O/preflight.json"
python3.14 -B kit/testnet/prepare.py plan --params "$P" --preflight "$O/preflight.json" --out "$O/plan.json"
python3.14 -B kit/testnet/prepare.py simulate --params "$P" --plan "$O/plan.json" --rpc "$RPC" --out "$O/simulation.json"
python3.14 -B kit/testnet/prepare.py explorer --params "$P" --plan "$O/plan.json" --out "$O/explorer"
python3.14 -B kit/testnet/prepare.py config-plan --params "$P" --plan "$O/plan.json" --rpc "$RPC" --out "$O/public-config-disabled.json"
```

`plan.json` contains complete deployment calldata, init code, constructor arguments, expected
addresses, source-file inventory/hash, git revision, compiled artifact hashes, parameter hash,
role assignments and plan hash. A source or parameter edit invalidates it, even on an uncommitted
worktree. `explorer` emits real Standard JSON compiler inputs and constructor/address metadata;
it does **not** submit verification or require an explorer key. `simulation.json` contains exact
expected deployed runtime bytes/hashes and its pin. Its raw trace remains alongside the isolated
simulation plan under `kit/testnet/output/simulation/<planHash>/`.

`config-plan` emits exact mode `testnet`, `enabled: "false"`, predicted addresses and the
simulation-derived vault hash. `depositOpen` stays `TBD`, so merely flipping enabled cannot
make it usable. Its scope is explicitly **public-plan-not-deployed**, not public acceptance.

**STOP for separate deployment approval.** No command here performs public deployment. An
approved operator reviews the unsigned transaction skeletons, independently reproduces the
simulation and handles funding/nonces/signing outside this kit. Wait for public-chain finality.
Then read back the actual deployment and produce the disabled public build inputs:

```bash
python3.14 -B kit/testnet/prepare.py verify --params "$P" --plan "$O/plan.json" --rpc "$RPC" --out "$O/verified.json"
python3.14 -B kit/testnet/prepare.py config --params "$P" --plan "$O/plan.json" --rpc "$RPC" --web-rpc https://sepolia.base.org --out "$O/web-config.json"
```

`verify` freshly re-simulates from the original pin (it does not trust an editable expected-code
receipt), then checks exact runtime bytes, implementation/singleton slots, Safe version/domain,
module/guard/fallback absence, owners/quorum, token roles and grant logs, initialization locks,
metadata/cap/decimals/chain identity, and every vault parameter. Reads are bound to one head and
its hash is rechecked. Readback records a current head, not a claim that a just-mined deployment
is finalized. `config` includes raw frontend inputs plus exact `NEXT_PUBLIC_TOKEN_MIGRATION_*`
names, remains disabled, and derives opening time from the vault's first code block. Its public
RPC is deliberately limited to the credential-free official endpoint; no private RPC URL is
published. Optional WalletConnect project ID remains empty; injected wallets work without it.

### Frozen ledger, commitment and activation

After the deposit deadline, choose a finalized block `N` and a scan start `FIRST` at/before
vault deployment. The complete net ledger must reconcile; a too-late scan cannot omit a funded
holder silently. Snapshot creation and signing verification independently recompute every
leaf/proof and re-read every entitlement at the frozen block. A mathematically balanced but
wrong tree is rejected. Retain the tree and snapshot together; never mix exercise directories.

```bash
python3.14 -B kit/testnet/prepare.py snapshot --params "$P" --plan "$O/plan.json" --rpc "$RPC" --block "$N" --from-block "$FIRST" --out "$O/snapshot"
python3.14 -B kit/testnet/prepare.py packet --params "$P" --plan "$O/plan.json" --rpc "$RPC" --action commit-root --safe-nonce "$K" --tree "$O/snapshot/tree.json" --out "$O/commit-root.json"
python3.14 -B kit/testnet/prepare.py check-packet --params "$P" --plan "$O/plan.json" --rpc "$RPC" --packet "$O/commit-root.json" --tree "$O/snapshot/tree.json" --out "$O/commit-checked.json"
```

After an approved quorum executes commitment and its receipt is confirmed, set `K` to the
Safe's newly read nonce. Within the execution window:

```bash
python3.14 -B kit/testnet/prepare.py packet --params "$P" --plan "$O/plan.json" --rpc "$RPC" --action activate --safe-nonce "$K" --tree "$O/snapshot/tree.json" --out "$O/activate.json"
python3.14 -B kit/testnet/prepare.py check-packet --params "$P" --plan "$O/plan.json" --rpc "$RPC" --packet "$O/activate.json" --tree "$O/snapshot/tree.json" --out "$O/activate-checked.json"
```

The activation packet is one Safe DELEGATECALL to the pinned MultiSendCallOnly, containing only
mint backing + activate. It rejects a different committed root/total, an already-funded vault,
insufficient mint headroom, active claims or a passed execution deadline. Both packets bind
chain, source/artifacts, parameters, addresses, snapshot hash, Safe nonce and exact EIP-712 hash.
Every Safe packet has a sibling `.builder.json`; the device must match the companion packet's
hash/nonce/operation/gas fields. A UI choosing a different multisend or gas policy creates a
**different transaction**: stop, do not approve it. Packet files are unsigned; `check-packet`
revalidates current eligibility and nonce, not a stored “OK” flag. Mining time can close a
window after a check; the contracts remain the final enforcement boundary.

### Recovery and rotation

Cancellation is Safe-only and only before commitment. Timeouts are permissionless, strictly
**after** their deadline. Refunds use the net V1 ledger, always pay the beneficiary, and cannot
run after claims have ever activated. Use separate scenario/output directories; these are
alternative histories, not a sequence to apply to an activated vault.

```bash
python3.14 -B kit/testnet/prepare.py packet --params "$P" --plan "$O/plan.json" --rpc "$RPC" --action cancel --safe-nonce "$K" --out "$O/cancel.json"
python3.14 -B kit/testnet/prepare.py packet --params "$P" --plan "$O/plan.json" --rpc "$RPC" --action expire-commit --out "$O/expire-commit.json"
python3.14 -B kit/testnet/prepare.py packet --params "$P" --plan "$O/plan.json" --rpc "$RPC" --action expire-execution --out "$O/expire-execution.json"
python3.14 -B kit/testnet/prepare.py packet --params "$P" --plan "$O/plan.json" --rpc "$RPC" --action refund --account "$BENEFICIARY" --out "$O/refund.json"
python3.14 -B kit/testnet/prepare.py packet --params "$P" --plan "$O/plan.json" --rpc "$RPC" --action rotate --safe-nonce "$K" --old-owner "$OLD" --new-owner "$NEW" --out "$O/rotate.json"
python3.14 -B kit/testnet/prepare.py check-packet --params "$P" --plan "$O/plan.json" --rpc "$RPC" --packet "$O/rotate.json" --out "$O/rotate-checked.json"
python3.14 -B kit/testnet/prepare.py verify-rotation --params "$P" --plan "$O/plan.json" --rpc "$RPC" --packet "$O/rotate.json" --out "$O/rotation-verified.json"
```

Rotation checklist:
- Bill approves old/new exact addresses; new signer proves control independently on the intended
  device, with a separate backup. Never disclose seeds/keys. Keep the old quorum available.
- Re-read owners/order and threshold. The packet computes `swapOwner`'s linked-list predecessor,
  keeps threshold unchanged and requires the **existing** quorum. No unilateral recovery exists.
- Check packet and device hash, then obtain separate authorization to sign. After execution,
  `verify-rotation` authenticates the historical packet, indexed Safe `ExecutionSuccess` receipt,
  nonce increment, new owner set and unchanged contract roles/wiring. It is intentionally an
  immediate readback: another Safe execution requires investigating the now-advanced nonce.
- Verify the removed key cannot authorize and the new key can, on actual devices during public
  acceptance. The local runner proves this with real Safe GS030 / approvedHashes, not hardware.
- Archive the old packet. Initial-governance `verify` now fails by design; do not rewrite historical
  params to hide rotation (that changes CREATE2 identity). Future operations after a public
  rotation require a separately reviewed governance-baseline extension; this kit does not
  silently accept an unapproved signer change. The contracts themselves remain fully governed.

## Fully exercised local rehearsal

```bash
python3.14 -B kit/testnet/rehearse.py --out "$O/new-local-rehearsal"
```

The output path must not already exist. The command verifies a fresh real Sepolia finalized pin,
starts/health-checks its own Anvil (`--accounts 0`, numeric loopback, chain84532), validates fork
origin before any write, exercises the **actual front-door commands**, and stops Anvil even on
failure. It tests real Safe below-quorum GS020; deposits and withdrawal; Safe cancellation;
commit and execution timeouts; ledger refunds and duplicate-refund rejection; frozen snapshots;
Safe root and atomic activation; formula and relayed Merkle claims; double claims; rotation;
removed-owner GS030 and new-owner authorization. Raw receipts are separated by scenario so
reverted branches never overwrite the successful history.

It also exercises rejected TBDs, stale/altered plans, wrong runtime/quorum, mixed/altered
snapshots, balanced-but-wrong allocations, wrong block identity, stale/tampered Safe nonces and
packets, invalid public/local configuration, late activation and refunds/cancel after activation.
Refunds, both timeouts and signer rotation are exercised after `validUntil`; no historical params
are rewritten to make recovery work.
Each command and exit status is saved in `cli.log`. `result.json: PASS` is **local-only evidence**.
No wallet UX, human-device signing, public-testnet deployment or production readiness is claimed.

For an independently owned local fork, read-only commands accept explicit `--local` and produce
mode `testnet-rehearsal` only with an HTTP loopback RPC. The frontend additionally requires a
loopback development page/build. Never relabel that config as public testnet or production.

## Offline gates and production preservation

```bash
python3.14 -B -m unittest discover -s __tests__/kit -p 'test_*.py' -v
forge build --deny warnings
forge test --no-match-path 'test/fork/**'
forge fmt --check
```

Ordinary Nx build/test/lint targets run the generated-source check, and test includes the new
stdlib suites. Token tests additionally compile privately and compare ABI, selectors and
normalized storage layout. `../token-v2/scripts/sepolia_source.py --check` rejects manual/stale
output; regeneration requires explicit `--write` after review. The testnet bytecode/CREATE2
addresses intentionally differ from production. Production source, ABI, creation/runtime
bytecode, layout and original kit inputs are separately measured against the before-change
receipt; equal production init code means equal production CREATE2 for unchanged arguments.
The unchanged production tests and full migration-launch suite remain mandatory. A parity or
fork pass is not an external audit.
