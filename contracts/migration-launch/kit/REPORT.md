# SURPLUS v1 → v2 launch: rehearsal report

Every number below comes from a file (sha256 at the end), measured at Base block **51,935,583**
(`0x2a3d465ca7407d2373bce06a2741e104785fefd0d43db7574a8230a310caa1b6`) or produced by the full-scale fork rehearsal of the monorepo contracts from that
state. USD figures use Chainlink ETH/USD at the pin, **$2,658.90**. The rehearsal runs on a
private anvil forked at the pin: nothing was broadcast to Base.

## Cohort

- **6,338 selected accounts** hold 91,050,022,388 v1 (91.05% of the 100,000,000,000 supply). This is a maximum-participation
  scenario: each selected address is impersonated to deposit its full historical balance. It is not an
  adoption forecast or proof that every wallet can authorize the calls through its real signing flow.
  - EOA: 2,005 holders, 58,335,928,637 v1 (58.34%)
  - EIP-7702 account: 2,573 holders, 27,605,194,697 v1 (27.61%)
  - ERC-4337 account: 1,749 holders, 4,473,872,988 v1 (4.47%)
  - Safe: 11 holders, 635,026,065 v1 (0.64%)
- Cohort provenance and historical balance checks live in the source run. This report does not perform
  a fresh holder census or certify control of the selected addresses; validate the source bundle separately.

## Not in the root

218 addresses hold 8,949,977,612 v1 (8.95%). Of that, 6,916,642,582 (6.9166%) can never migrate, and 2,033,335,030 (2.0333%) is the remaining conditional/unresolved bucket.
The remainder is not all proven recoverable: it includes ownership-dependent exits, unknown residuals
and immovable strays. Bucket descriptions below are source-run assessments, not deposit guarantees.

- **doppler-locked-launch-liquidity**: 6,915,899,381 v1 (6.9159%). Doppler's 2 launch positions in the main SURPLUS/WETH v4 pool, valued at the pin's sqrtPrice (pool status Locked: exitLiquidity always reverts)
  - Can it migrate: never. Who must act: nobody: it stays in the old pool as the depth the sale trades against
- **doppler-fee-contract-unclaimed-fees**: 989,038,993 v1 (0.989%). trading fees already collected into Doppler's fee contract 0xd59ce43e53d69f190e15d9822fb4540dccc91178, owed to its fee earners (989,038,985 owed; 8.17 v1 sent to it directly, owed to nobody)
  - Can it migrate: yes, once claimed. Who must act: each fee earner calls collectFees(poolId) from its own address, then deposits
- **other-v4-pools-and-uncollected-fees**: 311,500,511 v1 (0.3115%). the rest of the v4 PoolManager: other LPs in the main pool, the other v4 SURPLUS pools' LP principal, fees the Doppler positions earned but nobody collected yet, Uniswap protocol fees, other LPs' uncollected fees
  - Can it migrate: yes, except the Uniswap protocol fees. Who must act: LPs withdraw (PositionManager decreaseLiquidity/burn) then deposit; the Doppler share is released to the fee earners on their next collectFees
- **v2-v3-aerodrome-pools**: 183,865,102 v1 (0.1839%). 12 non-v4 AMM pools (token0() answers; factory() read on chain)
  - Can it migrate: yes. Who must act: each pool's LPs withdraw their liquidity, then deposit
- **non-wallet-contracts**: 549,428,207 v1 (0.5494%). 202 contracts that are not wallets (bridge adapter, bots, lockers, vaults)
  - Can it migrate: only if the owner / the contract's own rules move it to a wallet. Who must act: the owner (or, for the bridge adapter, whoever bridges back) moves it to a wallet, then deposits
- **burn-address**: 216,060 v1 (0.0002%). 0x…dEaD: nobody holds its key
  - Can it migrate: never. Who must act: nobody
- **sent-to-v1-contract**: 29,358 v1 (0.0%). sent by mistake to the v1 token contract itself (no function moves it)
  - Can it migrate: never. Who must act: nobody

## The launch batch

One Safe transaction (2-of-3, the real Safe 1.4.1 and MultiSendCallOnly) at 2,113,808 gas, under the 2^24 per-transaction cap.

- **Signed limits** (simulate, then sign): the simulation raised 138.1686 WETH, so `minWethOut` = 137.4777 WETH (× 0.995). The v2 budget is 6,018,114,932 (simulated + 0.1% + 10 wei). Execution equalled the simulation.
- **Sale:** 91,050,022,388 v1 sold for **138.1686 WETH** ($367,377):
  - Doppler v4 pool: 81,945,020,149 v1 → 134.8337 WETH
  - v3 1% tail pool: 9,105,002,239 v1 → 3.3348 WETH
- **Old pool price impact:** the sale drains the old pool's WETH. v1 per WETH went from 43,512,856 to 8,292,429,195, so v1 left outside the migration loses 99.48% of its pool price. The v2 opening price is a separate signed simulation-time marker.
- **Successor pool** (v2/WETH, LP fee 0.30% on chain, plus the 1.5% hook): opens at **43,512,856 v2 per WETH**, the simulation's pre-sale price.
  This is not a guarantee of realizable sale value. Fees, finite liquidity and other trades change exit
  proceeds, especially for large sellers. No extra single-sided liquidity is approved.
  - It is seeded with 138.1684 WETH + 6,012,102,829 v2, full range, about $734,752 of depth. The LP NFT (#3097527) is owned by the Safe.
  - The WETH raised and not seeded (dust from rounding) and the unused v2 budget went back to the Safe.
- **Final v2 supply:** 97,068,137,320: 91,050,022,388 backing every claim 1:1, plus 6,012,102,829 in the pool and 6,012,103 of unused budget returned to the Safe.

## Fee check (1.5% hook + 0.30% LP)

Live trades through the real hook after launch. In each one, the hook took exactly floor(1.5% × the pool's side of the unspecified currency):
- exact-in buy (1 WETH → v2): 646,072.81 v2
- exact-in sell (10M v2 → WETH): 0.003481 WETH
- exact-out buy (→ 10M v2): 0.003502 WETH
- exact-out sell (→ 0.2 WETH): 129,246.51 v2

The Safe then withdrew both halves (team and buyback) of both currencies, leaving the hook empty. The
contracts/fee-hook fork suite measures a small trade's all-in cost at 0.3001% (LP fee + price impact) +
1.4999% (hook): about 1.8%.

## Rival venues at the ~1.8% fee (siphon table, re-run)

A cheaper hookless pool for the same pair wins every trade up to V* ≈ fee gap × its depth ÷ 2. This is on the last 300 main-pool trades (median $129, largest $20,607).
- $50,000 rival: vs 0.05% ≤$438 (8.5% of volume), vs 0.3% ≤$375 (6.2% of volume), vs 1.0% ≤$200 (3.5% of volume)
- $100,000 rival: vs 0.05% ≤$875 (15.8% of volume), vs 0.3% ≤$750 (14.3% of volume), vs 1.0% ≤$400 (7.7% of volume)
- $250,000 rival: vs 0.05% ≤$2,188 (35.1% of volume), vs 0.3% ≤$1,875 (30.4% of volume), vs 1.0% ≤$1,000 (17.9% of volume)
- $1,000,000 rival: vs 0.05% ≤$8,750 (68.1% of volume), vs 0.3% ≤$7,500 (61.4% of volume), vs 1.0% ≤$4,000 (46.7% of volume)
- Depth a rival needs to take every trade: $2,355,050 (hookless v4 0.05%), $2,747,558 (v2/v3/v4 0.30%), $5,151,671 (v3 1%)
- Model reference depth (not an approved funding target): **$2,400,000** in-range. The rehearsal seed is about $734,752.
- Decided ops alert: in-range depth of **$125,000** in any rival pool. This threshold is a decision, not evidence that monitoring is running.
- Conditional model: breakeven leak 85.0%. Revenue at the historical volume ($317,634/day): $5,717/day, $4,764 of it to the hook.

## Failure paths at full scale

Each one starts from the same state (all 6,338 selected deposits made, window closed) and passes:
- The Safe never commits: after `commitDeadline` anyone calls `expireCommit()`, then a relayer pushes `refund()` to every holder (Multicall3, 200 per transaction). Every holder gets its exact v1 back, the vault ends empty, and no v2 is ever minted.
- A root is committed but nobody activates: after the execution window anyone calls `expireExecution()`, with the same refunds.
- The successor pool is initialized before the batch: the whole launch batch reverts (Safe `GS013`). Nothing is minted, activated, released or sold, and the Safe nonce is unused. Outsiders cannot initialize it at all: the hook admits only the settler (RealHookLaunch.fork.t.sol).
- A withdrawal after the deposit deadline is rejected (`LedgerWithdrawalsFrozen`), sampled across the cohort.
- v1 sent to the vault by plain transfer: nothing is rescuable while the vault holds exactly the ledger. After the transfer, the Safe's `rescueV1` returns exactly that excess, and the ledger's v1 stays.
- One signature is refused (`GS020`) with the Safe's nonce and the vault untouched; two sign `commitRoot`.

## Push distribution

- 53 Multicall3 `aggregate3` transactions pushed 6,338 claims. The 4 holders who had already claimed for themselves were skipped, and every holder received exactly its v2. A rerun paid nobody, and the relayer received nothing.
- Largest transaction: 8,448,030 gas (cap 16,777,216), 92,228 bytes of calldata (cap 131,072).
- Cost at Base's base fee at the pin (0.005 gwei, priority fee excluded): L2 444,969,765 gas = 0.002225 ETH, plus L1 data (GasPriceOracle upper bound) 0.000150 ETH = **0.002374 ETH** ($6) for all 6,338 holders.

## Outreach: who must act to take part

- **fee earner** (5):
  - `0x21e2ce70511e4fe542a97708e89520471daa7a66` (806,032,134 v1): claim, then deposit: a 3-of-6 Safe transaction from 0x21e2ce70511e4fe542a97708e89520471daa7a66 calling collectFees(0xfc25fdd217e288d03a877f0b7d49e0bbe52b2288c88de929125062569fc7eb2a) on the fee contract 0xd59ce43e53d69f190e15d9822fb4540dccc91178 (simulated at the pin: succeeds) releases 808,567,307 v1 + 8.4242 WETH to it (the owed amount plus its cut of fees still in the PoolManager); then approve + deposit that v1 in the migration vault before the deadline
  - `0xf60633d02690e2a15a54ab919925f3d038df163e` (173,856,508 v1): claim, then deposit: a transaction from 0xf60633d02690e2a15a54ab919925f3d038df163e calling collectFees(0xfc25fdd217e288d03a877f0b7d49e0bbe52b2288c88de929125062569fc7eb2a) on the fee contract 0xd59ce43e53d69f190e15d9822fb4540dccc91178 (simulated at the pin: succeeds) releases 192,160,455 v1 + 5.0636 WETH to it (the owed amount plus its cut of fees still in the PoolManager); then approve + deposit that v1 together with its wallet balance of 1,064,943,660 v1 in the migration vault before the deadline
  - `0xa564307f1fe4c5935098c05b12bb97b01b6b589a` (0 v1): claim, then deposit: a transaction from 0xa564307f1fe4c5935098c05b12bb97b01b6b589a calling collectFees(0xfc25fdd217e288d03a877f0b7d49e0bbe52b2288c88de929125062569fc7eb2a) on the fee contract 0xd59ce43e53d69f190e15d9822fb4540dccc91178 (simulated at the pin: succeeds) releases 28,900,969 v1 + 0.6248 WETH to it (the owed amount plus its cut of fees still in the PoolManager); then approve + deposit that v1 together with its wallet balance of 542,594,969 v1 in the migration vault before the deadline
  - `0x2cdd33d6ff2a897180c7f4e5a20f018bf0c16fd1` (9,150,343 v1): claim, then deposit: a transaction from 0x2cdd33d6ff2a897180c7f4e5a20f018bf0c16fd1 calling collectFees(0xfc25fdd217e288d03a877f0b7d49e0bbe52b2288c88de929125062569fc7eb2a) on the fee contract 0xd59ce43e53d69f190e15d9822fb4540dccc91178 (simulated at the pin: succeeds) releases 10,113,708 v1 + 0.2665 WETH to it (the owed amount plus its cut of fees still in the PoolManager); then approve + deposit that v1 together with its wallet balance of 297,141,877 v1 in the migration vault before the deadline
  - `0x418e10c3c19f5db0addb59aad1b9f436a9eb931e` (0 v1): nothing: its share moved to 0xf60633d02690e2a15a54ab919925f3d038df163e at block 46914291; it is owed nothing and holds no v1
- **non-wallet holder >= 10M** (5):
  - `0x498581ff718922c3f8e6a244956af099b2652b2b` (7,227,399,891 v1): no single owner. The Doppler launch liquidity cannot migrate. Every other v1 here belongs to v4 LPs (see the LP-owner entries) or to fees: LPs remove liquidity on the v4 PositionManager 0x7c5f5a4bbd8fd63184577525326123b519429bdc (modifyLiquidities: DECREASE_LIQUIDITY/BURN_POSITION + TAKE_PAIR), then deposit
  - `0xd59ce43e53d69f190e15d9822fb4540dccc91178` (989,038,993 v1): the fee earners claim it (see the fee-earner entries). 8.17 v1 was sent to it directly and is owed to nobody: no function releases it
  - `0x12cf078d3d4808dbdc69701f30b0b409aff89ec1` (516,816,640 v1): No special outreach. Holders of bridged SURPLUS (LayerZero OFT adapter) take part only if they bridge back to Base and deposit before the deadline; otherwise they miss the migration.
  - `0xbcf23f30a90f6d7c288facdc932ff8f8b68b0f30` (176,123,565 v1): its LPs remove their liquidity (NonfungiblePositionManager decreaseLiquidity + collect on 0x03a520b32c04bf3beef7beb72e919cf822ed34f1), then deposit the v1. LP owners with >= 10M are listed separately
  - `0x4ff1d40fb7b56665bf95d8d8e3a5320de46709a1` (17,808,497 v1): the owner 0xc8e45f393a5fab555f918106fc990df5d5647a10 calls EmergencyWithdraw(address,uint256)(0xc52aedec3374422d7510e294cfaa90799595cba3, 17808497171813178791050274); the v1 lands at 0xacf092af1b6c6e4899e45699bf3cb3aa32f34607, whose key holder then approves + deposits
- **LP owner >= 10M** (9):
  - `0x620e32dbddca653f03587aef6090a3f5cc9e6f65` (155,363,630 v1): 0x620e32dbddca653f03587aef6090a3f5cc9e6f65 removes the liquidity (modifyLiquidities (DECREASE_LIQUIDITY + TAKE_PAIR) on 0x7c5f5a4bbd8fd63184577525326123b519429bdc for token ids 2742479, 2742493, 3078149; modifyLiquidities (DECREASE_LIQUIDITY + TAKE_PAIR) on 0x7c5f5a4bbd8fd63184577525326123b519429bdc for token ids 2523652, 2533529, 3086518; decreaseLiquidity + collect on 0x03a520b32c04bf3beef7beb72e919cf822ed34f1 for token ids 5334608), which pays the v1 to the position holder; approves + deposits it before the deadline
  - `0x9a10b502901ec287a89f33026609bc56ce835996` (58,265,002 v1): 0x9a10b502901ec287a89f33026609bc56ce835996 removes the liquidity (modifyLiquidities (DECREASE_LIQUIDITY + TAKE_PAIR) on 0x7c5f5a4bbd8fd63184577525326123b519429bdc for token ids 2952813, 3046636, 3078591), which pays the v1 to the position holder; approves + deposits it before the deadline
  - `0xdecd504c466d891b7833de68838f0e2730e23a17` (37,312,026 v1): 0xdecd504c466d891b7833de68838f0e2730e23a17 removes the liquidity (decreaseLiquidity + collect on 0x03a520b32c04bf3beef7beb72e919cf822ed34f1 for token ids 6058256), which pays the v1 to the position holder; approves + deposits it before the deadline
  - `0x62e3a6f8a8689444c49684fdddbc164e2038807f` (25,053,188 v1): 0x62e3a6f8a8689444c49684fdddbc164e2038807f removes the liquidity (decreaseLiquidity + collect on 0x03a520b32c04bf3beef7beb72e919cf822ed34f1 for token ids 5391599), which pays the v1 to the position holder; approves + deposits it before the deadline
  - `0x73e3a22e9aec8a56818b9528e32aaea839a593d5` (17,547,408 v1): 0x73e3a22e9aec8a56818b9528e32aaea839a593d5 removes the liquidity (decreaseLiquidity + collect on 0x03a520b32c04bf3beef7beb72e919cf822ed34f1 for token ids 5724387), which pays the v1 to the position holder; approves + deposits it before the deadline
  - `0xafce6bb7c9d3f83ab430dd8a7ad56aa89a25aaea` (16,917,472 v1): 0xafce6bb7c9d3f83ab430dd8a7ad56aa89a25aaea removes the liquidity (modifyLiquidities (DECREASE_LIQUIDITY + TAKE_PAIR) on 0x7c5f5a4bbd8fd63184577525326123b519429bdc for token ids 3048100), which pays the v1 to the position holder; approves + deposits it before the deadline
  - `0x1df0ba02f94f01d08caef7cd2859a8085257669a` (16,549,961 v1): the contract's owner 0x186b12ceaf08fde22e32647fcc800e45876f5bd0, through that contract, removes the liquidity (decreaseLiquidity + collect on 0x03a520b32c04bf3beef7beb72e919cf822ed34f1 for token ids 6087275), which pays the v1 to the position holder; the owner then moves the v1 to its own wallet and approves + deposits it before the deadline
  - `0xa53d14896b82f65dc88f333b7738f2da4d8da539` (14,224,469 v1): the contract's owner 0xb5c8ebf701676594abd93da9a16bd5f4759c9982, through that contract, removes the liquidity (decreaseLiquidity + collect on 0x03a520b32c04bf3beef7beb72e919cf822ed34f1 for token ids 5551691, 5769967), which pays the v1 to the position holder; the owner then moves the v1 to its own wallet and approves + deposits it before the deadline
  - `0xac4754d4450f6d5ec1b610cdc0049bcfd8c52912` (12,529,622 v1): 0xac4754d4450f6d5ec1b610cdc0049bcfd8c52912 removes the liquidity (modifyLiquidities (DECREASE_LIQUIDITY + TAKE_PAIR) on 0x7c5f5a4bbd8fd63184577525326123b519429bdc for token ids 3084496), which pays the v1 to the position holder; approves + deposits it before the deadline

## Tree

`kit/launch.py snapshot` built the tree from the vault's own ledger at block 51,948,266: 6,338 leaves, total 91,050,022,388, root `0x703204306d075c428bc7a9436d6c50b5cbfcf96eb323fae2c0824d5954df79d4`. It was verified
three ways (VerifyTree, VerifyTreeBulk, an independent Python rebuild that re-reads every leaf from the ledger),
and it equals the root predicted from the cohort file alone.

## Inputs

- `pin.json`: sha256 `7176e921849bdcd91dc7f03f050f7041c5bf7bf6c30c9243c03894868d0e35f6`
- `cohort/cohort.json`: sha256 `b80938acabb258fdcce2fa6c141637398a3709b84a38c20e80cd90ed7968be07`
- `cohort/not-in-root.json`: sha256 `fd0154f9eac5db3aa38be5f059ef1000a1fe2b8470101bc255c4b8a626ff7c06`
- `outreach/outreach.json`: sha256 `2c6c78a47c94b0a5ea4a1546955db1b39184112fd3529d2f662c96e7481acc06`
- `siphon/siphon.json`: sha256 `5833137eb146335b1dbe3ab3a9c1c9d521d81194f2addd3a61aab446e7d649d0`
- `kit/output/rehearsal/result.json`: sha256 `a450c3a0b4181175fa842367d23f96a4d8a52d512b2e14e6dae5d63e08f41ac9`
- `kit/output/rehearsal/pin-block.json`: sha256 `61c77af780ab5e42e7f91329cd9be446e493f4503d48a2b9397b685806cfd0b9`
- `kit snapshot`: sha256 `19741c1e75105e28e4c95da99ba83cb0bf7e23f87d518af96de09bdc9fa7c3ef`
- `launch policy`: sha256 `2b07d95790ed9f9ed4ac65c859c447d32d5fa33ee3bfc0e411c44a6164a34987`
