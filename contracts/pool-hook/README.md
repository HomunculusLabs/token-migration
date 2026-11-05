# Successor-pool hook

`SurplusPoolHook` is the Uniswap v4 hook on the official V2/WETH successor pool. It has one job: only the launch
contract can create that pool. It charges no fee. The pool's own LP fee, 1.2%, is the only fee a swap pays, and it
goes to the pool's liquidity positions. **Not deployed; read [DESIGN.md](DESIGN.md) first.**

- `src/SurplusPoolHook.sol`: the hook. Its constructor takes
  `(poolManager, initializer, currency0, currency1, lpFee, tickSpacing)`, all public immutables. The hook address
  must carry exactly the flag `0x2000` (BEFORE_INITIALIZE), so the PoolManager calls it once, at initialization,
  and never on a swap or a liquidity change.
- `src/V4Minimal.sol`: the v4-core ABI slice. It holds `PoolKey`, `SwapParams`, `ModifyLiquidityParams`,
  `IPoolManager` and the `HookFlags` bits.
- `script/MineHookSalt.s.sol`: mines the CREATE2 salt. It runs locally, with no RPC and no broadcast.
- `test/`: unit suites. `test/fork/` holds the fork suites that run against the real Base PoolManager.

## Commands

From the repository root, run `npm ci` first; the tests' OpenZeppelin interfaces come from the workspace pin.

```sh
cd contracts/pool-hook
forge build --deny warnings
forge test --no-match-path 'test/fork/*'   # unit suites
forge fmt --check
```

### Fork suite

`test/fork/*` runs against a Base fork at `${FORK_URL:-http://127.0.0.1:18549}`, block
`${FORK_BLOCK:-51935583}`:

```sh
forge test --match-path 'test/fork/*' --fork-url "${FORK_URL:-http://127.0.0.1:18549}"
```

It asserts that the chain id is 8453 and the block is the pin. Set `FORK_BLOCK` to
re-pin. Forge forks in-process: it only reads state from the node and never sends it a transaction. Without a fork,
every fork suite skips.

### Mining the hook salt

```sh
cd contracts/pool-hook
HOOK_INITIALIZER=<launch helper> HOOK_CURRENCY0=<lower of v2/WETH> HOOK_CURRENCY1=<higher of v2/WETH> \
forge script script/MineHookSalt.s.sol --tc MineHookSalt
```

Optional variables:

| Variable | Default |
|---|---|
| `HOOK_POOL_MANAGER` | Base PoolManager |
| `HOOK_LP_FEE` | 12000 (1.2%) |
| `HOOK_TICK_SPACING` | 60 |
| `HOOK_DEPLOYER` | Arachnid's CREATE2 proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C` |
| `HOOK_SALT_START` | 0 |
| `HOOK_SALT_OUT` | `output/hook-salt.json` |

The script writes `{deployer, salt, address, initCodeHash, flags, constructorArgs}`. The salt is the smallest one
from the start whose address has exactly the flag `0x2000`. The init code is the creation code from this pinned
build (`bytecode_hash = "none"`) with the abi-encoded args appended. Deploy by sending `salt ++ initCode` to the
deployer, and check that the returned address matches the JSON. The launch kit (`kit/deploy_plan.py`) does all of
this itself; the script is for checking it by hand.
