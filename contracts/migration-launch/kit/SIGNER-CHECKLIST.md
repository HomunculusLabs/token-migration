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
    fee 3000, tick spacing 60 and the hook in `deployment.json`.
- **What `launch()` does**, top to bottom, all or nothing:
  1. v2 `mint(vault, V2_FOR_CLAIMS)`;
  2. vault `activateClaims()`;
  3. vault `withdrawV1ForSettlement(settler, V1_FOR_SALE)`;
  4. v2 `mint(settler, V2_FOR_POOL)`;
  5. settler `settle(settleParams())`.
  It then checks that the claims are backed and active, that the settler holds nothing, and that the Safe's
  owners, threshold, modules, guard, fallback handler and singleton are unchanged. Any failure reverts all of
  it. It runs only at this Safe, and only once.
- **The hook is the fee hook.** The hook in the new pool key reads `TREASURY()` = the decided fee
  recipient and `FEE_PIPS()` = 15000. The settler reverts `WrongHook` otherwise, and the kit's deploy dry
  run checks both before anyone signs.
- **The limits follow the rule.** `signed.minWethOut` = `unconstrained.wethRaised` × 0.995 and
  `signed.v2Budget` = `unconstrained.v2Seeded` + 10 wei. The signed run in
  `simulation.json` succeeded, raised the same WETH as the unconstrained run, and is recorded at
  `forkBlock`.
- **The seed is the decided split.** `settleParams.openTick` = `opening.openTick` (the old pool's tick at
  `forkBlock`, rounded to the 60 grid) and `settleParams.v2Ranges` = `opening.v2Side.ranges`. The signed run
  used `opening.v2Side.need` v2, at most `copySlack` wei short of `opening.v2Side.v1AboveOldPrice`, the v1
  the old pool held above its price.
- **The actual deadline.** Read the confirmed `rootCommittedAt()` and `EXECUTION_WINDOW()`. Activation
  must land at or before their sum; the separate `COMMIT_DEADLINE()` is not the activation clock.
- **Execute soon after the last signature.** If the old pool's price moves first, so that the sale would
  raise more than 0.5% less (below `minWethOut`), the launch reverts and nothing moves. Raising more only
  deepens the WETH side; the v2 side is fixed by the signed ranges. Rerun `safe-txs launch-batch`: it builds a
  new launch contract, at a new address, and a new hash to sign.

## After execution

- [ ] `vault.claimsActive()` is true, and `vault.verifySettlement()` reports fully backed with no v1 custody
      left.
- [ ] `settler.wethRaised()` ≥ `minWethOut`, and all `settler.positionCount()` LP NFTs from
      `settler.firstPositionId()` on are owned by the Safe.
- [ ] The settler holds no tokens.
