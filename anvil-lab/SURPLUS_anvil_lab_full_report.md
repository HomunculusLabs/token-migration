# SURPLUS Anvil Lab — Complete Evidence Report
*Generated 2026-09-23T22:00:39.664454+00:00 — all values extracted programmatically from run artifacts; raw traces in SURPLUS_anvil_lab_reports.zip*

## 1. Provenance
- Chain: Base (8453), pinned block **51702954** (`0x43cfa7110c95e2b3506e6328a83168ab7219d49347e8dd49e961c3333f073ff0`), timestamp 1790195255
- Hook: **0xbb7784a4d481184283ed89619a3e3ed143e1adc0**, runtime codehash `0x317314fa00365686fa78baafcd62d23ca4383b7d01a704ef5c600b8f8548e897`
- PoolKey: currency0 WETH, currency1 SURPLUS 0xc52aedec3374422d7510e294cfaa90799595cba3, fee 8388608 (dynamic-fee flag), tickSpacing 200; PoolKey hash verified = True
- Foundry: forge Version: 1.7.1
- Donors: 196 verified EOAs at pin, 55.0B SURPLUS coverage (55% of supply); balances cross-checked vs fork; sweep of 545,530 transfers reconciles to totalSupply (100B) exactly

## 2. Market context (DEXScreener/GeckoTerminal/CoinGecko, 2026-09-23)
- Price $0.0000845 | mcap=FDV $8.45M | ATH $0.00011953 (Sep 21, now -29%) | ATL $0.00001948 (Jun 10) | CG rank #1374
- Main v4 pool TVL $932k (160.7 WETH) | all-venue reserves ~$2.0M | vol24h ~$1.01M all-venue (main pool $310k = 33% of its TVL)
- Holders: 6,536 non-zero | Gini 0.976 | top-100 wallets = 79.0% of supply | median holding ≈ $1.09

## 3. Permission probes (all PASS, no reverts)
> [PASS] test_00_metadata_and_core() (gas: 600659)
>     ├─ emit log_named_int(key: "lower_human_price_range_native_tick_lower", val: 195600 [1.956e5])
>     ├─ emit log_named_int(key: "lower_human_price_range_native_tick_upper", val: 202600 [2.026e5])
>     ├─ emit log_named_uint(key: "before_sqrtPriceX96", val: 439097906899446537832922678320221 [4.39e32])
>     ├─ emit log_named_int(key: "before_native_tick", val: 172411 [1.724e5])
>     ├─ emit log_named_uint(key: "before_active_liquidity", val: 961209143792273142488285 [9.612e23])
>     ├─ emit log_named_uint(key: "before_lp_fee_pips", val: 12000 [1.2e4])
>     ├─ emit log_named_uint(key: "before_protocol_fee_packed", val: 0)
>     ├─ emit log_named_uint(key: "before_core_weth_principal_wei", val: 163729448094701223704 [1.637e20])
>     ├─ emit log_named_uint(key: "before_core_surplus_principal_raw", val: 5907148732737109178385290966 [5.907e27])
>     ├─ emit log_named_uint(key: "before_initialized_ticks", val: 26)
> [PASS] test_01_direct_add_then_remove() (gas: 167812)
>     ├─ emit log_named_int(key: "add_weth_wallet_change_wei", val: -1000000000000000 [-1e15])
>     ├─ emit log_named_int(key: "add_surplus_wallet_change_raw", val: 0)
>     ├─ emit log_named_int(key: "roundtrip_net_weth_wei", val: -1)
> [PASS] test_02_position_manager_add_then_remove() (gas: 291392)
>     ├─ emit log_named_uint(key: "new_local_position_id", val: 3083959 [3.083e6])
>     ├─ emit log_named_int(key: "posm_roundtrip_net_weth_wei", val: -1)
> Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 4.05s (4.50s CPU time)

## 4. Comparison runs — full metrics per size
Modes: 0 = direct sale; 1 = add LP → sell → remove; 2 = same + resell returned SURPLUS. Identical starting assets per size.
### 1M SURPLUS (0% of supply) — compare-1000000-20260923T210203Z-52484.txt
- pin: block 51702954, hook 0xbb7784a4…, codehash 0x317314fa…
- **mode 0**: net_weth 0.032160 | add_cost 0.000 | swap_in 0.032160 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 172415
- **mode 1**: net_weth 0.032160 | add_cost 1.000 | swap_in 0.032160 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 172415
- **mode 2**: net_weth 0.032160 | add_cost 1.000 | swap_in 0.032160 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 172415

### 100M SURPLUS (0% of supply) — compare-100000000-20260923T210249Z-53757.txt
- pin: block 51702954, hook 0xbb7784a4…, codehash 0x317314fa…
- **mode 0**: net_weth 3.158003 | add_cost 0.000 | swap_in 3.158003 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 172779
- **mode 1**: net_weth 3.158003 | add_cost 1.000 | swap_in 3.158003 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 172779
- **mode 2**: net_weth 3.158003 | add_cost 1.000 | swap_in 3.158003 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 172779

### 1B SURPLUS (1% of supply) — compare-1000000000-20260923T210250Z-53824.txt
- pin: block 51702954, hook 0xbb7784a4…, codehash 0x317314fa…
- **mode 0**: net_weth 27.126336 | add_cost 0.000 | swap_in 27.126336 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 175821
- **mode 1**: net_weth 27.126336 | add_cost 1.000 | swap_in 27.126336 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 175821
- **mode 2**: net_weth 27.126336 | add_cost 1.000 | swap_in 27.126336 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 175821

### 5B SURPLUS (5% of supply) — compare-5000000000-20260923T211439Z-79809.txt
- pin: block 51702954, hook 0xbb7784a4…, codehash 0x317314fa…
- **mode 0**: net_weth 83.350280 | add_cost 0.000 | swap_in 83.350280 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 185559
- **mode 1**: net_weth 83.350280 | add_cost 1.000 | swap_in 83.350280 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 185559
- **mode 2**: net_weth 83.350280 | add_cost 1.000 | swap_in 83.350280 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 185559

### 10B SURPLUS (10% of supply) — compare-10000000000-20260923T211440Z-79916.txt
- pin: block 51702954, hook 0xbb7784a4…, codehash 0x317314fa…
- **mode 0**: net_weth 112.494538 | add_cost 0.000 | swap_in 112.494538 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 193426
- **mode 1**: net_weth 112.494538 | add_cost 1.000 | swap_in 112.494538 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 193426
- **mode 2**: net_weth 112.494538 | add_cost 1.000 | swap_in 112.494538 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 193426

### 20B SURPLUS (20% of supply) — compare-20000000000-20260923T211441Z-79965.txt
- pin: block 51702954, hook 0xbb7784a4…, codehash 0x317314fa…
- **mode 0**: net_weth 136.327127 | add_cost 0.000 | swap_in 136.327127 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 203447
- **mode 1**: net_weth 135.668046 | add_cost 1.000 | swap_in 136.668046 | lp_returned 448346598037853824.000B | resold 0.000B | unsold 448346598037853824.000B | hook_delta 0 wei | endTick 203091
- **mode 2**: net_weth 136.327127 | add_cost 1.000 | swap_in 136.668046 | lp_returned 448346598037853824.000B | resold 448346598037853824.000B | unsold 0.000B | hook_delta 0 wei | endTick 203447

### 24B SURPLUS (24% of supply) — compare-24000000000-20260923T210309Z-54440.txt
- pin: block 51702954, hook 0xbb7784a4…, codehash 0x317314fa…
- **mode 0**: net_weth 141.316797 | add_cost 0.000 | swap_in 141.316797 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 206375
- **mode 1**: net_weth 140.826190 | add_cost 1.000 | swap_in 141.826190 | lp_returned 448346598037853824.000B | resold 0.000B | unsold 448346598037853824.000B | hook_delta 0 wei | endTick 206067
- **mode 2**: net_weth 141.316797 | add_cost 1.000 | swap_in 141.826190 | lp_returned 448346598037853824.000B | resold 448346598037853824.000B | unsold 0.000B | hook_delta 0 wei | endTick 206375

### 30B SURPLUS (30% of supply) — compare-30000000000-20260923T211442Z-80034.txt
- pin: block 51702954, hook 0xbb7784a4…, codehash 0x317314fa…
- **mode 0**: net_weth 146.685556 | add_cost 0.000 | swap_in 146.685556 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 210092
- **mode 1**: net_weth 146.348146 | add_cost 1.000 | swap_in 147.348146 | lp_returned 448346598037853824.000B | resold 0.000B | unsold 448346598037853824.000B | hook_delta 0 wei | endTick 209837
- **mode 2**: net_weth 146.685556 | add_cost 1.000 | swap_in 147.348146 | lp_returned 448346598037853824.000B | resold 448346598037853824.000B | unsold 0.000B | hook_delta 0 wei | endTick 210092

### 40B SURPLUS (40% of supply) — compare-40000000000-20260923T211443Z-80102.txt
- pin: block 51702954, hook 0xbb7784a4…, codehash 0x317314fa…
- **mode 0**: net_weth 152.478311 | add_cost 0.000 | swap_in 152.478311 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 215072
- **mode 1**: net_weth 152.273811 | add_cost 1.000 | swap_in 153.273811 | lp_returned 448346598037853824.000B | resold 0.000B | unsold 448346598037853824.000B | hook_delta 0 wei | endTick 214873
- **mode 2**: net_weth 152.478311 | add_cost 1.000 | swap_in 153.273811 | lp_returned 448346598037853824.000B | resold 448346598037853824.000B | unsold 0.000B | hook_delta 0 wei | endTick 215072

### 50B SURPLUS (50% of supply) — compare-50000000000-20260923T211446Z-80235.txt
- pin: block 51702954, hook 0xbb7784a4…, codehash 0x317314fa…
- **mode 0**: net_weth 156.178884 | add_cost 0.000 | swap_in 156.178884 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 219055
- **mode 1**: net_weth 156.041822 | add_cost 1.000 | swap_in 157.041822 | lp_returned 448346598037853824.000B | resold 0.000B | unsold 448346598037853824.000B | hook_delta 0 wei | endTick 218892
- **mode 2**: net_weth 156.178884 | add_cost 1.000 | swap_in 157.041822 | lp_returned 448346598037853824.000B | resold 448346598037853824.000B | unsold 0.000B | hook_delta 0 wei | endTick 219055

### 55B SURPLUS (55% of supply) — compare-55000000000-20260923T211526Z-81446.txt
- pin: block 51702954, hook 0xbb7784a4…, codehash 0x317314fa…
- **mode 0**: net_weth 157.569474 | add_cost 0.000 | swap_in 157.569474 | lp_returned 0.000B | resold 0.000B | unsold 0.000B | hook_delta 0 wei | endTick 220784
- **mode 1**: net_weth 157.454251 | add_cost 1.000 | swap_in 158.454251 | lp_returned 448346598037853824.000B | resold 0.000B | unsold 448346598037853824.000B | hook_delta 0 wei | endTick 220635
- **mode 2**: net_weth 157.569474 | add_cost 1.000 | swap_in 158.454251 | lp_returned 448346598037853824.000B | resold 448346598037853824.000B | unsold 0.000B | hook_delta 0 wei | endTick 220784

## 5. Migration curve (mode 0 ≡ mode 2 at every size; pool principal 163.729448 WETH; spot 32.1598 WETH per 1B)
| size | % supply | WETH | % of pool | avg ¢/$ vs spot |
|---|---|---|---|---|
| 1M | 0% | 0.0322 | 0.0% | 100.0¢ |
| 100M | 0% | 3.1580 | 1.9% | 98.2¢ |
| 1B | 1% | 27.1263 | 16.6% | 84.3¢ |
| 5B | 5% | 83.3503 | 50.9% | 51.8¢ |
| 10B | 10% | 112.4945 | 68.7% | 35.0¢ |
| 20B | 20% | 136.3271 | 83.3% | 21.2¢ |
| 24B | 24% | 141.3168 | 86.3% | 18.3¢ |
| 30B | 30% | 146.6856 | 89.6% | 15.2¢ |
| 40B | 40% | 152.4783 | 93.1% | 11.9¢ |
| 50B | 50% | 156.1789 | 95.4% | 9.7¢ |
| 55B | 55% | 157.5695 | 96.2% | 8.9¢ |

## 6. Verdicts
1. **Hook permits lower-price LP add/remove via BOTH routes** (custom PoolManager callback + deployed PositionManager); roundtrip cost ≈1 wei; hook takes 0 WETH on every path (`hook_delta 0 wei` in all 36 scenario runs).
2. **LP route is exactly neutral**: mode 2 = mode 0 − ≤1 wei at all 12 sizes. LP inert ≤10B (range never reached); range fully crossed ≥20B. Mode-1 gross exceeds mode-0 by self-funded WETH — the recycling pattern the README's interpretation table flags.
3. **Recovery is bounded by the pool**: 55% participation drains 96.2% of 163.73 WETH; marginal realized price at the end <1% of spot. Coordination cannot mint more WETH than the pool holds.

## 7. Discovery JSON (verbatim)
```json
{
  "status": "RPC-observed at pinned block; not a source-code audit",
  "chainId": 8453,
  "blockNumber": 51702954,
  "blockHash": "0x43cfa7110c95e2b3506e6328a83168ab7219d49347e8dd49e961c3333f073ff0",
  "timestamp": 1790195255,
  "poolId": "0xfc25fdd217e288d03a877f0b7d49e0bbe52b2288c88de929125062569fc7eb2a",
  "poolManager": "0x498581ff718922c3f8e6a244956af099b2652b2b",
  "stateView": "0xa3c0c9b65bad0b08107aa264b0f3db444b867a71",
  "initializeBlock": 46077742,
  "initializeLog": {
    "address": "0x498581ff718922c3f8e6a244956af099b2652b2b",
    "topics": [
      "0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438",
      "0xfc25fdd217e288d03a877f0b7d49e0bbe52b2288c88de929125062569fc7eb2a",
      "0x0000000000000000000000004200000000000000000000000000000000000006",
      "0x000000000000000000000000c52aedec3374422d7510e294cfaa90799595cba3"
    ],
    "data": "0x000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000000c8000000000000000000000000bb7784a4d481184283ed89619a3e3ed143e1adc00000000000000000000000000000000000019525207af12cbc615782c2414c150000000000000000000000000000000000000000000000000000000000038658",
    "blockHash": "0x274cd5bcab1837042725bef8086fb1676d1fb1d18477782a5d557ec8c25816ad",
    "blockNumber": "0x2bf172e",
    "blockTimestamp": "0x6a088b3f",
    "transactionHash": "0xb04d2518c495311c11d92040d6c1c16ac0606f49430302e0030bc459a61199cb",
    "transactionIndex": "0x4d",
    "logIndex": "0x120",
    "removed": false
  },
  "poolKey": {
    "currency0": "0x4200000000000000000000000000000000000006",
    "currency1": "0xc52aedec3374422d7510e294cfaa90799595cba3",
    "fee": 8388608,
    "tickSpacing": 200,
    "hooks": "0xbb7784a4d481184283ed89619a3e3ed143e1adc0"
  },
  "poolKeyHashVerified": true,
  "slot0": {
    "sqrtPriceX96": "439097906899446537832922678320221",
    "tick": 172411,
    "protocolFee": 0,
    "lpFee": 12000
  },
  "keyUsesDynamicFees": true,
  "hookRuntimeHash": "0x317314fa00365686fa78baafcd62d23ca4383b7d01a704ef5c600b8f8548e897",
  "hookPermissionsByAddress": {
    "afterRemoveLiquidityReturnDelta": false,
    "afterAddLiquidityReturnDelta": false,
    "afterSwapReturnDelta": false,
    "beforeSwapReturnDelta": false,
    "afterDonate": false,
    "beforeDonate": false,
    "afterSwap": true,
    "beforeSwap": true,
    "afterRemoveLiquidity": true,
    "beforeRemoveLiquidity": false,
    "afterAddLiquidity": true,
    "beforeAddLiquidity": true,
    "afterInitialize": false,
    "beforeInitialize": true
  },
  "optionalGetterProbes": {
    "owner()": {
      "error": "eth_call: {'code': 3, 'message': 'execution reverted'}"
    },
    "poolManager()": {
      "raw": "0x000000000000000000000000498581ff718922c3f8e6a244956af099b2652b2b"
    },
    "getHookPermissions()": {
      "raw": "0x00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    }
  },
  "eip1967SlotProbes": {
    "implementation": {
      "slot": "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc",
      "value": "0x0000000000000000000000000000000000000000000000000000000000000000"
    },
    "admin": {
      "slot": "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103",
      "value": "0x0000000000000000000000000000000000000000000000000000000000000000"
    },
    "beacon": {
      "slot": "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50",
      "value": "0x0000000000000000000000000000000000000000000000000000000000000000"
    }
  },
  "limitations": [
    "Address flags identify callbacks, not what their code does.",
    "Zero EIP-1967 slots do not rule out every proxy/delegation pattern.",
    "Current LP fee is not necessarily all-in or next-swap fee.",
    "No position is declared permanently locked by this script."
  ]
}
```