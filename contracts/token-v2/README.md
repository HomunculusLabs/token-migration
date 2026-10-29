# SurplusTokenV2 (SUR-661) — local draft

`SurplusTokenV2` is the Base-canonical successor ERC-20. It is an OpenZeppelin 4.9.6
`ERC20Capped + AccessControl + UUPS` implementation behind an `ERC1967Proxy`, which initializes it in its
constructor. It is **not** deployed or audited. Read [DESIGN.md](DESIGN.md) first: the parameters, the role
matrix, the upgrade risk and the storage-layout procedure are all there.

- `initialize(name, symbol, cap, governance)` takes the launch kit's `params.json` values, which are still TBD.
  It reverts on any chain other than Base (8453) and mints nothing.
- The governance Safe receives `DEFAULT_ADMIN_ROLE`, `MINTER_ROLE`, `BURNER_ROLE` and `UPGRADER_ROLE`. The
  deploying account receives no role.
- `mint(to, amount)` requires `MINTER_ROLE` and cannot exceed the cap. `burn(amount)` requires `BURNER_ROLE`
  and burns the caller's own balance.
- `storage-layout.json` is the committed storage layout. `scripts/check-storage-layout.sh` fails when the
  build differs from it.

## Local checks

After `npm ci` at the repository root:

```sh
cd contracts/token-v2
forge build --deny warnings
forge test
forge fmt --check
bash scripts/check-storage-layout.sh
cd ../..
npx nx run @surplus/contracts.token-v2:build
npx nx run @surplus/contracts.token-v2:test
npx nx run @surplus/contracts.token-v2:lint
npx nx run @surplus/contracts.token-v2:layout
```

The tests use placeholder metadata and amounts and a contract that stands in for the Safe
(`test/GovernanceDouble.sol`). None of them is a launch value, and a pass does not prove any Safe
configuration.
