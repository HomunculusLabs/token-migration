# SUR-658 — successor-pool fee hook (local only)

`SurplusFeeHook` is a Uniswap v4 hook for the official v2/WETH successor pool. Every swap through the pool pays a
1.5% fee in the swap's unspecified currency. The fee is split into a team half and a buyback half, and only the
treasury Safe can withdraw either. **Not deployed; read [DESIGN.md](DESIGN.md) first.**

- `src/SurplusFeeHook.sol`: the hook. Its constructor takes
  `(poolManager, treasury, initializer, currency0, currency1, lpFee, tickSpacing)`, all public immutables.
  The hook address must carry exactly the flags `0x2044`.
- `src/V4Minimal.sol`: the v4-core ABI slice. It holds `PoolKey`, `SwapParams`, `ModifyLiquidityParams`,
  `IPoolManager` and the `HookFlags` bits. `contracts/migration-launch` can import it through a remapping such as
  `@surplus/fee-hook/=../fee-hook/` (add `../fee-hook` to its `allow_paths`).
- `script/MineHookSalt.s.sol`: mines the CREATE2 salt. It runs locally, with no RPC and no broadcast.
- `test/`: unit suites. `test/fork/` holds the fork suites that run against the real Base PoolManager.
- `evidence/`: red→green output for each review finding (H1, H3, H2/H4).

## Commands

From the repository root, run `npm ci` first; the tests' OpenZeppelin interfaces come from the workspace pin.

```sh
cd contracts/fee-hook
forge build --deny warnings
forge test --no-match-path 'test/fork/*'   # unit suites
forge fmt --check
cd ../..
npx nx run @surplus/contracts.fee-hook:build
npx nx run @surplus/contracts.fee-hook:test
npx nx run @surplus/contracts.fee-hook:lint
npx nx run @surplus/contracts.fee-hook:fork   # needs a Base fork, see below
```

### Fork suite

The `fork` target runs `test/fork/*` against `${FORK_URL:-http://127.0.0.1:18549}` at block
`${FORK_BLOCK:-51935583}`. It asserts that the chain id is 8453 and the block is the pin. Set `FORK_BLOCK` to
re-pin. Forge forks in-process: it only reads state from the node and never sends it a transaction. Without a fork,
every fork suite skips.

### Mining the hook salt

```sh
cd contracts/fee-hook
HOOK_TREASURY=<safe> HOOK_INITIALIZER=<launch helper> HOOK_CURRENCY0=<lower of v2/WETH> \
HOOK_CURRENCY1=<higher of v2/WETH> forge script script/MineHookSalt.s.sol --tc MineHookSalt
```

Optional variables:

| Variable | Default |
|---|---|
| `HOOK_POOL_MANAGER` | Base PoolManager |
| `HOOK_LP_FEE` | 3000 |
| `HOOK_TICK_SPACING` | 60 |
| `HOOK_DEPLOYER` | Arachnid's CREATE2 proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C` |
| `HOOK_SALT_START` | 0 |
| `HOOK_SALT_OUT` | `output/hook-salt.json` |

The script writes `{deployer, salt, address, initCodeHash, flags, constructorArgs}`. The salt is the smallest one
from the start whose address has exactly the flags `0x2044`. The init code is the creation code from this pinned
build (`bytecode_hash = "none"`) with the abi-encoded args appended. Deploy by sending `salt ++ initCode` to the
deployer, and check that the returned address matches the JSON.
