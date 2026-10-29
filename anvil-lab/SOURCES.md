# Technical sources

These establish protocol/tool behavior and deployed infrastructure, **not SURPLUS-specific hook observations**. Source inspection during preparation: September 23, 2026. Upstream main branches can change; local PoolKey/hash checks bind test inputs to the observed deployment.

- Uniswap Base deployments: https://developers.uniswap.org/docs/protocols/v4/deployments
- PoolKey-derived pool IDs: https://github.com/Uniswap/v4-core/blob/main/src/types/PoolId.sol
- Hook flags, callbacks, return deltas: https://github.com/Uniswap/v4-core/blob/main/src/libraries/Hooks.sol
- Core state layout: https://github.com/Uniswap/v4-core/blob/main/src/libraries/StateLibrary.sol
- TickMath: https://github.com/Uniswap/v4-core/blob/main/src/libraries/TickMath.sol
- FullMath: https://github.com/Uniswap/v4-core/blob/main/src/libraries/FullMath.sol
- Pool swap and liquidity accounting: https://github.com/Uniswap/v4-core/blob/main/src/libraries/Pool.sol
- Swap steps: https://github.com/Uniswap/v4-core/blob/main/src/libraries/SwapMath.sol
- PositionManager: https://github.com/Uniswap/v4-periphery/blob/main/src/PositionManager.sol
- PositionManager actions: https://github.com/Uniswap/v4-periphery/blob/main/src/libraries/Actions.sol
- Anvil: https://www.getfoundry.sh/anvil
- Anvil reference: https://www.getfoundry.sh/reference/anvil/anvil
- Anvil RPC methods: https://www.getfoundry.sh/anvil/rpc-methods
- Forge testing: https://www.getfoundry.sh/forge/testing
- Current Bankr overview (not a substitute for launch-specific code): https://docs.bankr.bot/token-launching/overview/

The v4 manager is shared across pools. This package reconstructs pool-level core principal rather than treating the PoolManager's entire WETH balance as SURPLUS liquidity.
