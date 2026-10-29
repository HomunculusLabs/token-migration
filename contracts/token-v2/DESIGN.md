# DESIGN.md — SurplusTokenV2 (SUR-661)

**Status: local draft. Not audited, not deployed.** Tests run against a real `ERC1967Proxy` with placeholder
parameters and a contract standing in for the Safe. They do not prove the Safe's signers or threshold (SUR-662).

`SurplusTokenV2` is `ERC20CappedUpgradeable + AccessControlUpgradeable + UUPSUpgradeable` from OpenZeppelin
contracts-upgradeable **4.9.6** (the workspace npm pin), built with solc **0.8.28**. It always runs behind an
`ERC1967Proxy` whose constructor calls `initialize`, so no transaction can find the proxy uninitialized. The
implementation's constructor calls `_disableInitializers()`, so the implementation contract itself can never
be initialized.

## 1. Parameters

| Parameter | Value | Source |
|---|---|---|
| `name`, `symbol` | **TBD** | launch kit `params.json`; passed to `initialize` |
| `cap` | **TBD** | launch kit `params.json`; passed to `initialize`; must be > 0 |
| `governance` | **TBD**: the Base Safe (SUR-662) | launch kit `params.json`; passed to `initialize` |
| decimals | 18 | fixed by OZ `ERC20Upgradeable`; not a parameter |
| canonical chain | **Base, chain id 8453. Decided 2026-09-24 (Bill).** | `CANONICAL_CHAIN_ID`, enforced in `initialize` |

`initialize` reverts on an empty name or symbol (`InvalidMetadata`), on a zero cap, on any chain other than
Base (`InvalidCanonicalChain`), and on a `governance` address with no code (`InvalidGovernance`). The code
check rejects an EOA, the zero address, or a Safe address that has been predicted but not yet deployed, so
the Safe must exist before the proxy is created. It cannot prove that the address is the intended Safe.

The test values (`PLACEHOLDER Surplus v2`, `PLACEHOLDER`, a 1,000,000-token cap, 600,000 backing and a
250,000 LP budget) are fixtures, not proposed tokenomics.

## 2. Supply and mint policy

- **Zero initial supply.** `initialize` mints nothing, to anyone.
- **Only `MINTER_ROLE` mints**, and OZ Capped rejects any mint that would take `totalSupply` above `cap`.
  At launch only the Safe holds `MINTER_ROLE`.
- **Launch batch.** The migration launch order was decided 2026-09-28 (see `contracts/migration/DESIGN.md`
  §8): `activateClaims`, the v1 sale and the pool launch execute in one Safe transaction. The token's part of
  that transaction is two calls from the Safe:
  `mint(vault, backing)`, where `backing` is the committed `totalClaimable` that
  `MigrationVault.activateClaims` requires the vault to hold, and `mint(launchHelper, lpBudget)`. A Safe
  transaction is atomic, so if the second mint would exceed the cap, the first mint reverts with it.
  `backing + lpBudget <= cap` is a constraint that `params.json` must satisfy.
- **Burn.** `burn(amount)` destroys the caller's own balance and lowers `totalSupply`. It requires
  `BURNER_ROLE`. The fee-hook buyback needs a real burn: a transfer to a dead address only locks tokens and
  leaves `totalSupply` unchanged. There is no `burnFrom`, so a burner can destroy only tokens it holds. The
  Safe holds the role at launch and can grant it to a buyback executor later.
- **The cap bounds outstanding supply, not lifetime issuance.** Every burn frees the same amount of mint
  headroom, and the Safe can mint it again. Tokenomics that promise a lifetime issuance limit would need a
  different rule, which would be an upgrade.
- **Mint limiter (epoch throttle), added 2026-10-09.** Defense-in-depth against a compromised or rogue
  Safe: without it, a MINTER_ROLE holder can print the entire remaining cap in one transaction. The
  throttle bounds mint *velocity*: at most `limitPerEpoch` mintable per `epochLength` seconds, turning
  instant full dilution into dilution the community can observe, react to, and stop with a role revoke.
  - **Ships DISENGAGED.** `_mintLimitPerEpoch == 0` (the storage-zero default) means unconstrained —
    the atomic launch batch mints `backing + lpBudget` in one transaction and must stay unconstrained
    by construction. Engagement is a post-launch Safe action; nothing about launch depends on it.
  - **`setMintLimit(limitPerEpoch, epochLength)`** — `DEFAULT_ADMIN_ROLE` only. The FIRST call fixes
    the epoch grid (`epochLength`, anchor = its timestamp); later calls may change only the amount.
    `limitPerEpoch == 0` lifts the limit (same grid stays fixed). Engagement opens a fresh epoch
    budget; it is never retroactive.
  - **Hard reset per epoch.** Unused allowance does not roll over. Lowering the limit below what the
    current epoch already minted zeroes the remaining budget until the next epoch — never underflows.
  - **Cap still binds absolutely.** The limiter throttles; the cap remains the hard ceiling.
  - Storage: four appended slots (352–355, where `__gap` began); the gap shrinks 50→46. Nothing
    inherited moved (`storage-layout.json` regenerated). The Sepolia variant carries the same code.

## 3. Role matrix

Every role is administered by `DEFAULT_ADMIN_ROLE`, which is OZ's default; the contract sets no other admin.
`initialize` grants all four roles to `governance`. The account that deploys the implementation and the
proxy receives nothing.

| Function | Required | Held at launch by | Notes |
|---|---|---|---|
| `mint(to, amount)` | `MINTER_ROLE` | Safe | `totalSupply + amount <= cap` |
| `burn(amount)` | `BURNER_ROLE` | Safe | burns the caller's own balance only |
| `upgradeTo(impl)`, `upgradeToAndCall(impl, data)` | `UPGRADER_ROLE` | Safe | only through the proxy; `impl` must be UUPS (ERC-1822 check) |
| `grantRole(role, account)`, `revokeRole(role, account)` | `DEFAULT_ADMIN_ROLE` | Safe | covers every role, the admin role included |
| `renounceRole(role, account)` | `account == msg.sender` | each holder, for itself | irreversible, see below |
| `initialize(name, symbol, cap, governance)` | `initializer`: one call | consumed by the proxy constructor | cannot run again; the implementation is locked |

Transfers, approvals, `increaseAllowance` and `decreaseAllowance` are standard, permissionless ERC-20.

Role ids, for on-chain read-backs:

| Role | Id |
|---|---|
| `DEFAULT_ADMIN_ROLE` | `0x0000000000000000000000000000000000000000000000000000000000000000` |
| `MINTER_ROLE` | `0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a6` |
| `BURNER_ROLE` | `0x3c11d16cbaffd01df69ce1c404f6340ee057498f5f00246190ea54220576a848` |
| `UPGRADER_ROLE` | `0x189ab7a9244df0848122154315af71fe140f3db0fe014031783b0946b8c9d2e3` |

- `DEFAULT_ADMIN_ROLE` can grant any role to anyone, including `UPGRADER_ROLE`. **Holding the admin role
  is therefore equivalent to holding upgrade authority.**
- If the last `DEFAULT_ADMIN_ROLE` holder renounces or revokes that role, nobody can ever grant a role
  again. If the last `UPGRADER_ROLE` holder does the same, the token can never be upgraded again. There is
  no recovery path for either.
- After deployment, verify on chain that:
  - `hasRole(role, safe)` is true for all four roles, and `hasRole(role, deployer)` is false for all four;
  - the proxy's creation transaction emitted exactly four `RoleGranted` events, each naming the Safe;
  - `name`, `symbol` and `cap` equal `params.json`, and `totalSupply` is 0;
  - the ERC-1967 implementation slot holds the verified implementation, whose slot 0 reads `0xff`
    (initializers disabled).

## 4. Upgrade authority and its risk

`UPGRADER_ROLE`, the Safe at launch, can replace the implementation. **A governance-approved upgrade can
change anything**: balances, allowances, the cap, the mint and burn rules, roles, and transfer behavior.
`upgradeToAndCall` also runs arbitrary code in the proxy's storage context. **The cap does not restrain a
malicious or mistaken upgrade**, because it binds only the implementation that enforces it. The token is
exactly as trustworthy as the Safe's signer set and threshold.

The contract guards against these accidents:
- initializing the implementation (disabled in its constructor);
- initializing the proxy twice (`initializer`);
- calling an upgrade function on the implementation instead of the proxy (`onlyProxy`);
- upgrading to a contract that does not implement ERC-1822's `proxiableUUID`, which could leave the proxy
  with no upgrade function.

It does **not** guard against a storage-incompatible implementation. OZ 4.9 has no on-chain layout check,
and a successor that moves a variable silently corrupts balances or roles. Section 5 is the only guard.

There is no timelock: an approved upgrade takes effect in the Safe transaction that executes it.

## 5. Storage layout and future upgrades

The proxy's state lives in these slots (`storage-layout.json` has the full record):

| Slot | State |
|---|---|
| 0 | `Initializable._initialized` (offset 0), `_initializing` (offset 1) |
| 51, 52, 53 | `_balances`, `_allowances`, `_totalSupply` |
| 54, 55 | `_name`, `_symbol` |
| 101 | `_cap` |
| 202 | `_roles` (`mapping(bytes32 => RoleData)`; `members` is `RoleData`'s first field) |
| 352–401 | `SurplusTokenV2.__gap`, reserved for successor state |
| `0x3608…2bbc` | ERC-1967 implementation slot, `keccak256("eip1967.proxy.implementation") - 1` |

All other slots below 402 are the inherited OZ modules' own `__gap` arrays.

Two checks hold the layout:
- `test/SurplusTokenV2StorageLayout.t.sol` reads raw proxy storage with `vm.load` at the slots above, with
  known values, before and after an upgrade. Moving any of them fails the test.
- `scripts/check-storage-layout.sh` (Nx target `layout`) regenerates the layout with
  `forge inspect SurplusTokenV2 storageLayout --json`, normalizes it, and diffs it against the committed
  `storage-layout.json`. It exits non-zero on any difference. Normalizing drops AST ids and the per-entry
  contract path and sorts keys, so the output is the same on every machine.

To write a successor:
1. Keep every existing variable, its type and its order, and keep the inherited contracts in their current
   order. Add new state in one of two ways:
   - declare it in a contract derived from `SurplusTokenV2`, where the first new variable lands at slot 402;
   - or declare it in `SurplusTokenV2` before `__gap` and shrink `__gap` by exactly the number of slots added,
     so the gap still ends at 401.
2. Never change a role's preimage string. Role ids are `_roles` keys, so a renamed role strips its holders.
3. Set any new state with a `reinitializer(n)` function, called through `upgradeToAndCall` in the same Safe
   transaction. That way no one else can call it first.
4. Diff the successor against the deployed layout: `LAYOUT_CONTRACT=<Successor> bash scripts/check-storage-layout.sh`.
   Every existing entry other than `SurplusTokenV2.__gap` must keep its slot, offset and type, and new
   entries may only use slots from that gap or slots after 401. Anything else moves live state. Once the
   diff has been reviewed, rerun with `--write` and commit the new snapshot together with the code. If the
   successor is a new contract, also change the script's default contract to it, so the `layout` target
   keeps checking the implementation that will be live.
5. `SurplusTokenV2StorageLayout.t.sol` must pass unmodified. Add an upgrade test from the deployed
   implementation to the successor that preserves state, as `test_SafeUpgradePreservesBalancesAllowancesSupplyMetadataCapAndRoles` does.
6. Do not change the OpenZeppelin version as part of a successor without this procedure. OZ 5's upgradeable
   contracts keep state in ERC-7201 namespaces instead of these slots, so they are not a drop-in successor.

## 6. Deliberately not included

- **No transfer tax.** Swap fees belong to the v4 pool hook on its own pool. A token-level tax would charge
  every transfer on every venue and break integrations that expect the amount sent to arrive.
- **No bridge or OFT.** Base is canonical. Whether to bridge, and with what authorities, is SUR-663 and gets
  its own review.
- **No permit (EIP-2612).** Adding it later means new state (EIP-712 fields and nonces), so it goes through
  section 5 like any other upgrade.
- No pause, no freeze or blacklist, no cap setter, no `burnFrom`, and no upgrade timelock.
- No deployment script. Deploying the implementation and then
  `new ERC1967Proxy(implementation, abi.encodeCall(SurplusTokenV2.initialize, (name, symbol, cap, safe)))`
  from `params.json` is left to the launch kit.

## 7. Evidence

- `test/SurplusTokenV2.t.sol` covers the deploy parameters and every `initialize` rejection. On roles, it
  checks the four grants to the Safe and that the deployer holds nothing and cannot mint, upgrade or grant.
  It covers the launch-batch mints, the cap boundary (the cap exactly, then one wei over, alone and inside
  the batch) and non-minters. For burn, it covers the supply drop, the freed headroom compared with a
  dead-address send, delegating the role to an executor, and non-burners. It checks ERC-20 behavior through
  the proxy and the upgrade guards, and an append-only upgrade performed by the Safe that preserves
  balances, allowances, supply, metadata, cap and roles.
- `test/SurplusTokenV2StorageLayout.t.sol` pins the storage slots (section 5).
- `test/SurplusTokenV2Migration.t.sol` runs `MigrationVault` against the real proxy.
- `test/GovernanceDouble.sol` is the Safe's stand-in: one operator, atomic batches. It shows the token's
  behavior when a contract governs it. It says nothing about Safe configuration.

## 8. Open decisions (deployment blockers)

| Decision | Owner | Needed before deployment |
|---|---|---|
| Token name and symbol | Bill/Mac | exact bytes in `params.json` |
| Cap, vault backing and LP budget | Bill/Mac | values in `params.json`, with `backing + lpBudget <= cap`. Backing is the committed claim total at the decided 1:1 ratio |
| Governance Safe: address, signers, threshold, rotation | Bill/Mac (SUR-662) | a real Base Safe, a below-threshold rejection and a quorum-executed call, plus the section 3 read-backs |
| Buyback executor that receives `BURNER_ROLE` | Bill/Mac (fee hook) | the executor's design and review; until then only the Safe can burn |
| Bridge, if any | Bill/Mac (SUR-663) | a separate specification and review |
| Independent security review | Bill/Mac + reviewer | an audit of the implementation and this layout, and a fork rehearsal of the deployment |
