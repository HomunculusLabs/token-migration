# Base Sepolia rehearsals, October 2026

**Testnet only: Base Sepolia, chain 84532.** Every address below is a throwaway test contract holding
test tokens. Never send real V1, or anything else of value, to any address in this file.

Each run deployed a fresh test V1, V2 token, migration vault and Safe with this kit, using throwaway
keys, on the public Base Sepolia chain (not a fork). Base Sepolia has no copy of V1's mainnet pools,
so every launch sells into on-chain copies of them, built from the live mainnet curve and scaled
down. These runs prove the mechanics on a public chain. The sale and pool economics of record stay
with the Base-mainnet fork rehearsal in `kit/REPORT.md`. The first public deployment, on 2026-10-09,
is `01-public-deployment.txt`.

Look up any address or transaction below at https://sepolia.basescan.org. Each run's raw outputs,
keys and scripts stay in the operator's local, gitignored `kit/testnet/output/<run>/`; this file is
the public summary.

## Runs at a glance

- 2026-10-22: refunds after a missed deadline, a rescue of a plain transfer, and the first full
  launch, run from the kit's launch batch.
- 2026-10-23: real wallets. A team member deposited, withdrew and claimed through the migration
  page, and a team signer executed the Safe steps from the Safe app.
- 2026-10-27: the one-call launch contract (`MigrationLaunch`), end to end.
- 2026-10-27 to 29: a team run, with two team wallets on the migration page beside scripted
  holders.
- 2026-10-28 to 29: a load rehearsal with 5,000 wallets and 800,000 test V1.

## 2026-10-22: refunds, rescue, and the first full launch

**Refunds after a missed deadline.** The 2026-10-09 vault
`0x0E6DF1D9Af7C4F7c2e2e282E67fbcA8977967140` reached its commit deadline with no claims list
committed. `expireCommit` switched it to refunds, and refunds of 400 and 200 V1 paid both
depositors. A second refund reverted.

**Rescue.** In a separate run, the Safe recovered V1 that had been sent to the vault by plain
transfer, which sits outside the deposit ledger, before claims opened. After the deposit deadline,
a deposit, a withdrawal and a commit from a non-owner all reverted.

**Full launch, contract calls only.**

- Safe `0x85BC71E3e8bF74d728e74E0dbB6Fd2E46493a3F9` (2 of 4), vault
  `0xB25A85fb484f29CA01545c0baD5d89F272006461`, V2 `0x4acBF59234E0E8901439cd6e45603BFCb04a667A`,
  settler `0xfa4628acE9F46F0D1De3f1003cC7de6b2bDA909D`, fee hook
  `0xEeE5F137F602A6beeA992C56ad7811f3DA0a2044`.
- Four holders deposited directly on the contract, including a partial and a full withdrawal, for a
  net 9,000 test V1.
- The kit's launch batch was simulated on a private fork to set the signed limits, then signed by 2
  owners and executed unchanged (same safeTxHash):
  `0x8e8e7c3df8582682e748bdb5ec9329fde4272c315a870bcbbe640dbb9dd71b8b`.
- Selling 8,100 V1 into the copy of the Doppler v4 pool and 900 V1 into the copy of the v3 1% pool
  raised 0.2691 WETH. The new V2/WETH pool opened at the pre-sale price, full range, with that WETH
  and 345.8 V2. Its LP NFT (#32905) is owned by the Safe. 14 of 14 post-launch checks passed.
- Claims: 2 self-claims and 1 claim sent by another wallet, 9,000 V2 in total. All 6 abuse attempts
  reverted. The vault ended with 0 V1 and 0 V2.
- Fee hook: 4 live trades (exact in and exact out, buy and sell) each paid exactly floor(1.5%),
  split team and buyback. The Safe withdrew the team share in both tokens. A withdrawal by anyone
  but the treasury reverted, and so did an outsider opening a second pool on the hook.
- The pool copies reproduce the live mainnet curve at Base block 52,944,825: all 37 bands of the
  Doppler pool plus the v3 pool's 59, with ticks shifted by -92,200 and liquidity divided by
  100,000. They are plain pools with a fixed 1.2% fee, which is what the Doppler hook charged in
  fork swaps; the hook's own code is not copied. The same sale against the real pools on a private
  mainnet fork raised 267.9 WETH, and the testnet result matches it per venue, at scale, to about
  5e-13.

## 2026-10-23: real wallets on the migration page and in the Safe app

- Safe `0xef3dA66165767a3BD07571897f9518C3B72b4Ac3` (2 of 4), vault
  `0xfDA140a968b4bD6760a0037cddC487a717C89Edc`, V2 `0xB9409b717d22eeD6B5d76590322950462D0f92e1`.
  The launch used the kit's batch (a Safe DELEGATECALL into MultiSendCallOnly).
- A team member used the migration page with MetaMask: deposited 10, withdrew 10, deposited 10, then
  claimed 10 V2 after the launch
  (`0x993062492324d5efe34917e474bc827d5c9473b9585b706ccde49b59188c7daa`). MetaMask had made the
  account an EIP-7702 smart account, so third-party senders submitted its deposits and withdrawal;
  the vault still credited and paid the holder's own address. The holder sent the claim.
- Two scripted holders added 7,000. The snapshot had 3 leaves and 7,010 V1, equal to the vault's net
  ledger.
- Each Safe transaction was queued in the Safe app with one throwaway signature. A team signer
  confirmed and executed the commit
  (`0x45b21f10e4a9f4d7f8963388a34191884afe80ec2d49e05bde1b3e7ca0f4ad1b`) and the launch
  (`0x1f7257812d26bb9861254bde49accc6baea3a21aa7681a7f8517edd8a127eeb9`) from the Safe app.
- The launch passed 14 of 14 checks. The sale raised 0.2662 WETH, exactly the signed simulation
  (minimum 0.2649). The new pool held that WETH and 342.0 V2, and its LP NFT (#32953) is owned by
  the Safe.
- Claims totalled 7,010 V2, and 6 of 6 abuse attempts reverted. The vault ended at 0 V1 and 0 V2.
  Four live trades paid exactly 1.5%, the Safe withdrew the team share, and 3 of 3 guards held.

## 2026-10-27: the one-call launch contract

- Safe `0xBb90af49b9cf0bEB6D195C738856701bB9a727Aa` (2 of 4), vault
  `0x3B728A464a0fE60229B4c600ba1168b95a6aBCb1`, V2 `0xE6c4Bb9B47c6c88c763a6614E84385f44AC4e738`,
  launch contract `0x6c467d46160e3F3c208e34eC568c61cBAD40ad23` (deployed with CREATE2; its runtime
  code hash equals the kit's).
- Net ledger 9,000 V1 from four holder shapes (a partial withdrawal, two deposits, a net-zero holder
  and a single deposit), plus 5 V1 sent by plain transfer, which stays outside the ledger as
  designed.
- Commit `0x58530d76e81461abb4ede5d8138e049dbbfc722358b325db8b025ed31fb5e8bc`. The launch is one
  Safe DELEGATECALL into `MigrationLaunch.launch()`:
  `0xcab8a6fddf8e9ec577e5a70eae27235ca349708ec0a6f7f3fdb4db47b4a8a41f` (3,738,775 gas).
- Every check held. The sale raised 0.2698 WETH (signed floor 0.2685, equal to the signed
  simulation). Claims were active and fully funded. The vault's remaining V1 was exactly the 5-V1
  plain transfer. All 3 LP NFTs (33043 to 33045) are owned by the Safe, the settler kept nothing, and
  the pool opened at the signed tick 71700.
- Claims: a self-claim, and a claim sent by another wallet that paid the depositor while the sender
  received nothing. All 6 guards reverted.
- A second `launch()` through the Safe reverted (GS026), and a direct call from a non-Safe address
  reverted.
- Fee hook: 4 trade shapes charged exactly 1.5000%. The Safe withdrew the team share in both tokens.
  A withdrawal by anyone else, a second pool on the hook and a re-initialization all reverted.

## 2026-10-27 to 29: team run on the migration page

- Safe `0x54023c007666108ecCBd7bC51640B82d2fC436Ae` (2 of 4), vault
  `0xBC3C625408E6D294A3DC64CAefAFA2DDCb1aBae5`, V1 `0x851ffC2E948cD1E96d3FAb81a2d84835236b133c`, V2
  `0xD92a7C1A29FE361482A55CB3A57ED9bE8431296c`, launch contract
  `0x0ef497916C2B5D0323B61Be9b6ACCFEc3229c0d6`, settler
  `0x8CC97445ce0D9AD5e7832923444043a27bfF5a09`, fee hook
  `0xCaFb6506014F014D3Feb29cf2d723Be36BF32044`.
- Five depositors: two team wallets on the migration page (1,000 and 10 V1) and three scripted
  holders (4,500, 2,000 and 2,500 V1). Snapshot at block 51110709: 5 leaves, 10,010 V1, root
  `0x30b59df1e5c77acb88862864cae2b6bece530ebdadc307cb977bb02336e126af`.
- Commit `0x409e4c588522700cabb9758494e3dd2935e944d867ea07f39357c739ffc73830`. Launch
  `0x14a0ce1f19d5aa17353c28dbc83f24b12be67e2bc02aedaa18a7bad3dfb652d1`, one Safe DELEGATECALL into
  `launch()` (3,745,640 gas). Both were executed with throwaway owner keys.
- At the launch block (51433067), claims were active and the vault held exactly 10,010 V2 against
  10,010 claimable, with no V1 left. The sale raised 0.2709 WETH (signed minimum 0.2695, equal to
  the signed simulation). All 3 LP NFTs (33098 to 33100) are owned by the Safe, the pool opened at
  the signed tick 71700, and the unused V2 budget went back to the Safe.
- Claims so far: 10,000 of 10,010 V2, including a self-claim and a claim sent by another wallet.
  Three guards reverted: a second self-claim, a self-claim after a list claim, and a claim by a
  holder who had withdrawn everything.

## 2026-10-28 to 29: load rehearsal, 5,000 wallets

- Safe `0xE6722a93f8A1A1e7Aa947cd205cc00f4e8C2A004` (2 of 4), vault
  `0xe37c7A1915d1E2AFc2930C6a40fd2e53FA8dAb94`, V1 `0xBB7FE630aCF5f482A76b145A6969465376373d78`, V2
  `0xA0ba2c0c64d15E5Ec3C2C3F6399DF31B81704500`, launch contract
  `0xd3f1A76ADD77E7FfBE4D66143fbfb04802781Fcf`, settler
  `0x6320e1b45942fBaa959c6C9D8beeDb9Ea834205D`, fee hook
  `0xD98195033F0A8a3f3003aA10209f50Cc04002044`.
- 5,000 scripted wallets held 800,000 test V1, shaped like the September V1 holder distribution
  (the top 10 wallets held 30% of the ledger). The pool copies were built from the mainnet curve of
  the day (41 bands in the Doppler copy, 54 in the v3 copy) and held 117.5 WETH.
- Deposits followed a 4-hour arrival curve compressed into about 104 minutes. Every wallet
  deposited, and the ledger closed at exactly 800,000 V1.
- **Withdrawals were not exercised in this run.** The test harness called `withdraw(uint256)`, a
  function the vault does not have, instead of `withdrawV1(uint256)`, so every scripted withdrawal
  reverted without reaching the vault's logic. Replaying three of them at block 51578733, two
  minutes before the deadline, `withdrawV1` succeeds and `withdraw(uint256)` reverts. Withdrawals
  before the deadline are covered by the vault's unit tests, by the 2026-10-09 and 2026-10-23 runs
  on this chain, and by the mainnet-fork rehearsal.
- Snapshot at block 51587089: 5,000 leaves, net ledger 800,000 V1, root
  `0x10d79ff32f33c4a57e978adefc316af3734c611ba86f624fb1a6fd366cf1e7a2`. Commit
  `0x58c9291ed75c1159b80ba6d7affda8f3a5e0e2615643a242f2b912c55887a6a9`.
- Launch: one Safe DELEGATECALL into `launch()`,
  `0x8f2066bf0784f2d62081bf1f78c443d54f655561ccc417518439b638ddba0e62` (3,581,371 gas). An earlier
  execution went out before the launch contract was deployed. A DELEGATECALL to an address with no
  code succeeds and does nothing, so that attempt only used up Safe nonce 1. Deploy the launch
  contract before executing the launch.
- At the launch block (51631464), claims were active and the vault held exactly 800,000 V2 against
  800,000 claimable, with no V1 left. The sale raised 102.574783250806667509 WETH (signed minimum
  102.0619, equal to the signed simulation). All 3 LP NFTs (33112 to 33114) are owned by the Safe,
  the settler kept nothing, the pool opened at the signed tick 71100, and the unused V2 budget went
  back to the Safe. 14 of 14 post-launch checks passed.
- Claims: all 4,758 leaves scripted to claim did so. 3,595 were sent by the depositor's own wallet,
  and 1,163 were sent by another wallet and paid to the depositor. The other 242 leaves never claim,
  by design. On chain, 780,855 V2 has been claimed and the vault holds exactly the 19,145 V2 those
  242 leaves are owed.
- Trading: 200 wallets each sold 20% of their V2 through the new pool. All 10 sampled sells
  succeeded with the fee hook's event, and the run recorded each fee as exactly floor(1.5%) of the
  swap amount. A separate set of 4 swap shapes (exact in and exact out, in both directions) charged
  1.5000%, the Safe withdrew the team share, and both guards held.

Operational lessons from this run. These concern the test harness and operations, not the
contracts:

- Copy function signatures from the ABI. A call to a function that does not exist reverts with no
  error data, and a probe with the same typo will appear to confirm a wrong diagnosis.
- Fund every sending wallet first. An unfunded sender silently failed about 950 claims, which then
  went through on a re-run.
- Send from each key one transaction at a time. Parallel sends from one key race each other's
  nonces.
- Deploy the launch contract before executing the launch.

## Not yet covered on testnet

- Signers on separate devices: rejecting too few signatures, and replacing a signer.
- Recovery on the website from rejected signatures, reloads, disconnects, and network or account
  changes. These were rehearsed on a fork, not yet on testnet.
