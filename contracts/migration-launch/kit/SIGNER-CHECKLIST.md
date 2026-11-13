# Signer checklist: the two launch Safe transactions

Check every line before you sign. If anything differs, do not sign; ask the kit operator to rerun
`safe-txs`. The kit writes everything referred to below to `kit/output/safe-txs/`.

## Every Safe transaction

1. **The Safe.** The address at the top of the Safe UI is `safe` in `<name>.calldata.txt`, on Base
   (chain 8453). Basescan shows it as a Safe proxy whose implementation is SafeL2 1.4.1
   (`0x29fcB43b46531BcA003ddC8FCB67FFE91900C762`), with the agreed owners and threshold; the Safe UI
   shows version `1.4.1+L2`. Do not apply the UI's "New version is available" update: the kit refuses
   any other base contract. Also inspect enabled modules, guard and fallback handler: the planned new
   Safe has none. A module can transact without fresh owner signatures. Stop on any configuration not
   explicitly reviewed.
2. **The nonce.** The UI's nonce is `nonce` in `<name>.calldata.txt`. No other transaction is queued at
   or below that nonce.
3. **Nothing is paid.** Value 0 on every call. safeTxGas, baseGas and gasPrice are 0. gasToken and
   refundReceiver are the zero address.
4. **The hash.** The safeTxHash your device shows (hardware wallet or UI "Transaction details") equals
   `<name>.safeTxHash.txt` character for character. The kit computed it twice (Python EIP-712 and the
   Safe's own `getTransactionHash`) and both agreed. This is the check that covers everything else.

## commitRoot (`commitRoot.*`)

- One call. It is a CALL (operation 0) to the vault, `vault` in `deployment.json`.
- Method `commitRoot(bytes32 root, uint256 totalClaimable)`. `root` and `totalClaimable` equal the
  snapshot's `snapshot.json` (`root`, `totalClaimable`). Someone other than the operator has rebuilt that
  snapshot and got the same root, checked every leaf against the ledger, and verified the snapshot
  block's canonical hash and Base finality. Do not accept a tree without its snapshot manifest.
  Record the approved parameter file hash and deployment addresses with this packet.
- The deposit deadline has passed, and `commitDeadline` has not.

## The launch (`launch-batch.*`)

The launch is one contract, MigrationLaunch (`src/MigrationLaunch.sol`), built for this launch's numbers and
run once by the Safe. Everything it will do is in its code and its numbers, so you check the contract, then
one short transaction.

- **The launch contract is deployed, and it is the reviewed one.** `launchContract` in
  `launch-batch.deploy.json` has code on Base, `cast keccak $(cast code <launchContract>)` equals
  `runtimeCodeHash` in the same file, and Basescan shows it verified as `MigrationLaunch`. A Safe
  DELEGATECALL to an address with no code succeeds and does nothing, so never execute before it is deployed.
- **Target:** that `launchContract` address.
- **Operation:** 1, DELEGATECALL. The Safe app labels it "Unexpected delegate call", because the target is not
  one of Safe's own contracts. That is expected for this address and no other. A DELEGATECALL runs the target's
  code as the Safe, with all of the Safe's powers, so a DELEGATECALL to any other address, or to this address
  with another code hash, can take over the Safe. If the UI shows a different address here, stop.
- **Data:** `0x01339c21`, `launch()` with no arguments. Value 0.
- **Its numbers**, read from the contract (Basescan "Read Contract", or `cast call`):
  - `SAFE()`, `VAULT()`, `SETTLER()` and `V2()` are the addresses in `deployment.json`;
  - `V2_FOR_CLAIMS()` equals `fromVault.backing` in `simulation.json`, which is the vault's own
    `totalClaimable()`;
  - `V1_FOR_SALE()` equals `fromVault.v1In`, the vault's net ledger;
  - `V2_FOR_POOL()` equals `signed.v2Budget`, and `MIN_WETH_OUT()` equals `signed.minWethOut`;
  - `OPEN_TICK()` equals `opening.openTick`, and `NEW_POOL_ID()` equals `opening.newPoolId`;
  - `settleParams()` equals `settleParams` in `launch-batch.safe-tx.json`: its new pool key names v2, WETH,
    fee 12000 (1.2%), tick spacing 60 and the hook in `deployment.json`.
- **What `launch()` does**, top to bottom, all or nothing:
  1. v2 `mint(vault, V2_FOR_CLAIMS)`;
  2. vault `activateClaims()`;
  3. vault `withdrawV1ForSettlement(settler, V1_FOR_SALE)`;
  4. v2 `mint(settler, V2_FOR_POOL)`;
  5. settler `settle(settleParams())`.
  It then checks that the claims are backed and active, that the settler holds nothing, and that the Safe's
  owners, threshold, modules, guard, fallback handler and singleton are unchanged. Any failure reverts all of
  it. It runs only at this Safe, and only once.
- **The hook is the pool hook.** The low 14 bits of the hook's address are exactly `0x2000` (pool
  creation only, so it can never act on a swap), and it reads `INITIALIZER()` = the settler,
  `LP_FEE()` = 12000 and `TICK_SPACING()` = 60. The settler reverts `WrongHook` on any other flags or
  initializer, and the kit's deploy dry run checks all of it before anyone signs.
- **The limits follow the rule.** `signed.minWethOut` = `unconstrained.wethRaised` × 0.97 and
  `signed.v2Budget` = `unconstrained.v2Seeded` + 10 wei. The signed run in
  `simulation.json` succeeded, raised the same WETH as the unconstrained run, and is recorded at
  `forkBlock`.
- **The seed is the decided split.** `settleParams.openTick` = `opening.openTick` (the old pool's tick at
  `forkBlock`, rounded to the 60 grid) and `settleParams.v2Ranges` = `opening.v2Side.ranges`. The signed run
  used `opening.v2Side.need` v2, at most `copySlack` wei short of `opening.v2Side.v1AboveOldPrice`, the v1
  the old pool held above its price.
- **The v3 tail gets at most 70% of what it can take.** `V1_SOLD_ON_V3_TAIL()` equals `sale.tailIn` in
  `simulation.json`, `sale.tailCapacityBps` is 7000, and `sale.tailIn` is at most `sale.tailCapacity` × 7000 /
  10 000. `sale.tailCapacity` is the most v1 the tail could take at `forkBlock`, measured up to `sale.v1In` / 0.7,
  past which the cap cannot matter. The other 30% is room for others to trade on the tail before execution.
- **The actual deadline.** Read the confirmed `rootCommittedAt()` and `EXECUTION_WINDOW()`. Activation
  must land at or before their sum; the separate `COMMIT_DEADLINE()` is not the activation clock.
- **The last required owner executes the launch instead of signing it.**
  1. Owners confirm the launch in the Safe app until it is one confirmation short of the threshold. A
     confirmation is a signature or an on-chain approval (`approveHash`). Both are public and both count.
     No other owner confirms after that.
  2. The last required owner has not confirmed in any way. They execute from an ordinary wallet that is
     itself an owner: an EOA with no smart-account features, for example a hardware wallet. Not a Safe,
     and not another smart-contract or ERC-4337 account.
  3. In the Safe app (labels as of November 2026) they answer "Would you like to execute the transaction
     immediately?" with "Yes, execute". The app remembers the last answer, so read it. If the app shows "Who
     will pay gas fees", they choose "Connected wallet", never the sponsored option ("Sponsored by" or
     "Sponsored gas"). Their own wallet sends the transaction and pays its gas.
  4. They check every line above first. Their device shows no safeTxHash, because they send a transaction
     instead of signing a message. They compare the safeTxHash in the Safe app's transaction details with
     `launch-batch.safeTxHash.txt`. On the device they check that the transaction goes to the Safe's address
     with value 0. The Safe runs only a transaction the other owners confirmed and reverts any other.
  5. Why: every confirmation is public. Safe's Transaction Service serves each signature to anyone, and an
     approval is on chain. With a complete set, anyone can execute the launch inside a transaction of their
     own and trade around it. They can take the gap between what the sale would raise when they run it and
     `minWethOut`: 3% of the simulated raise, and more if the price has risen since. An executing owner's
     approval is valid only in a transaction their own address sends, so only someone who controls an
     owner's wallet can execute the launch. A sponsored or relayed execution makes the last owner sign
     first, which completes the public set. A Safe or smart account that executes leaves its own approvals
     for anyone to use.
  6. Execute within minutes of the simulation. If prices move first, so that the sale would raise more than
     3% less (below `minWethOut`), the launch reverts and nothing moves. In a replay of a 20.84B v1 sale on
     33 hours of trading (12 and 13 November 2026), 1.0% of launches reverted when executed 15 minutes
     after their simulation, 4.6% after 60 minutes and 11.4% after 120 minutes.
  7. Raising more only deepens the WETH side; the v2 side is fixed by the signed ranges. That is true only
     when one of the Safe's own owners executes.
  8. After a revert, rerun `safe-txs launch-batch`: it builds a new launch contract, at a new address, and a
     new hash to sign. Do not sign it until the old nonce has been spent with a Safe rejection: the reverted
     launch kept its nonce and its signatures, so two signed launches would be live at once (RUNBOOK, "Sale
     slippage").

## After execution

- [ ] `vault.claimsActive()` is true, and `vault.verifySettlement()` reports fully backed with no v1 custody
      left.
- [ ] `settler.wethRaised()` ≥ `minWethOut`, and all `settler.positionCount()` LP NFTs from
      `settler.firstPositionId()` on are owned by the Safe.
- [ ] The settler holds no tokens.
