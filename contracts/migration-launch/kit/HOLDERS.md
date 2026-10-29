# SURPLUS v1 → v2 migration: for holders

## The deal

- **1:1.** Every v1 you deposit becomes one v2. There is no bonus and no penalty, and the same rate
  applies to everyone.
- **What happens to the pool.** The v1 you deposit is sold, and all of the money raised opens the new
  v2/WETH pool at the opening price selected in the launch simulation. Matching an opening price does
  not guarantee what you can sell for: fees, available liquidity and other trades affect your proceeds.
- **Trading fee.** On the new pool: 0.30% to liquidity providers plus 1.5% to the SURPLUS treasury (half
  for the team, half allocated to buybacks). Purchases and any burns require separate treasury
  decisions and transactions; fee accrual alone does not execute a buyback.
- **Chain.** Base only.

## Contract addresses

These are filled in on launch day, after deployment and Basescan verification. Check every address on
Basescan before you approve anything.

- v1 (what you deposit): `0xC52aeDec3374422d7510E294cfAa90799595CBa3`
- Migration vault: `TBD at deployment`
- v2 token: `TBD at deployment`
- The Safe that governs the migration: `TBD at deployment`
- New v2/WETH pool hook: `TBD at deployment`

## How to take part

1. **Approve.** Call `approve(<vault>, <amount>)` on the v1 token.
2. **Deposit.** Call `deposit(<amount>)` on the vault before the deposit deadline (`TBD`). You can deposit
   more than once.
3. **Change your mind?** Until the deadline, `withdrawV1(<amount>)` returns your v1. From the deadline on,
   the ledger is frozen so the claim list can be built from it.
4. **Get your v2.** You don't have to do anything. A relayer sends every depositor their v2 (it can only
   pay each entry to its own account). Your claim never expires. If you would rather not wait, claim it
   yourself:
   - `claimProRata()` on the vault: no proof needed. It pays you exactly your net deposit × 1.
   - or `claim(index, account, amount, proof)` with your entry from the published tree.

   Either way, you are paid once.

## Check your own entry

After the deadline the full claim list is published as `tree.csv` (`index,account,amount`) and `tree.json`
(the same, with each proof), together with the root the Safe commits.

- **Your amount.** Find your address in `tree.csv`. The amount is your net deposit (deposited minus
  withdrawn) × 1, in wei. You can read your net deposit from the vault yourself:
  `availableToWithdraw(<your address>)`.
- **Your proof.** Your leaf is `keccak256(abi.encodePacked(index, account, amount))`. Fold it with your
  proof in `tree.json` (hash each pair in sorted order) and you should get the committed root. Or just
  call `claim(...)` with those values in a simulation: it succeeds only if your entry is in the root.
- **Already claimed?** `isClaimed(index)` covers Merkle claims only. A proofless `claimProRata()`
  emits `ProRataClaimed(account, amount)` without setting that bitmap. Check the vault's confirmed
  `ClaimPaid` and `ProRataClaimed` events (or the reconciled distribution report) for your account.
  Your current v2 balance is not claim history: you may have transferred tokens since receiving them.

## If launch does not activate, you can get your v1 back

- If the Safe never commits the claim list by the commit deadline, anyone can call `expireCommit()`. Every
  depositor can then get their exact v1 back.
- If the list is committed but v2 is never released within the execution window, anyone can call
  `expireExecution()` after `rootCommittedAt() + EXECUTION_WINDOW()`, with the same result.
  After activation, v1 has been sold; these refund paths are no longer available. Unpaid v2 claims
  remain backed and never expire.
- In both cases, `refund(<your address>)` (anyone can call it for you) or `withdrawV1` returns your full
  net deposit in v1.
- Sending v1 to the vault by plain transfer is **not** a deposit, so it is not in the claim list. Always
  use `deposit`.

## Who can't simply deposit

Some v1 sits in contracts rather than wallets: liquidity pools and the Doppler fee contract. The owners of
those positions must first withdraw their v1 (remove liquidity or claim fees), then deposit like anyone
else. REPORT.md lists the largest ones and what each must do.

If you hold SURPLUS bridged to another chain, the migration happens on Base only. Bridge it back to Base
and deposit before the deadline; there is no separate process for bridged tokens.
