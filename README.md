# Filing PoC — RA-1: DepositPool delegated-claim payout redirect (Morpheus / MOR)

Foundry fork PoC: a keeper whitelisted via `setClaimSender` to *trigger* claims
for a staker can choose the payout destination freely whenever the staker has
not pinned a `claimReceiver` — `claimFor` mints the staker's entire MOR pending
to the keeper's own address. The same flaw in `claimReferrerTierFor` steals
referrer-tier rewards. Two tests, each with its controls in-test.

## Run it (one command)

Prerequisites: Foundry (`forge`) and an **archive-capable** Ethereum mainnet
RPC endpoint (the fork is pinned to a historical block).

```bash
ETH_RPC_URL=<your archive RPC endpoint> forge test
```

The RPC endpoint is read from the `ETH_RPC_URL` environment variable (see
`foundry.toml` → `[rpc_endpoints]`); the fork block is pinned inside the test
(`vm.createSelectFork("mainnet", 26329065)`). No keys or endpoints are
hardcoded, no mainnet transaction is sent — everything runs on a local fork.

RPC note: the free `https://eth.drpc.org` endpoint passes. The free
publicnode endpoint intermittently routes to non-archive backends that fail
in `setUp()` with `historical state … is not available`; retry or use any
archive endpoint you trust.

## Pinned block

Ethereum mainnet block **26,329,065**.

## What the tests prove

- `test_RA1_ClaimForRedirect` (gas 5,494,176) — harness accrues 2,154.73 MOR of
  pending for a 200,000 USDT staker; the staker whitelists a keeper
  (`setClaimSender`), pins no receiver. Controls: a non-whitelisted caller
  reverts `DS: invalid caller`; after `setClaimReceiver`, the keeper's chosen
  receiver is ignored. Attack: the keeper calls
  `claimFor(0, staker, attacker)` → `MintMessageSent(receiver = attacker,
  amount = 10,130.06 MOR)` (pending settled over the claim window), staker
  pending → 0.
- `test_RA2_ReferrerTierRedirect` (gas 3,794,003) — same pattern on the stETH
  pool's live referrer tiers: the keeper redirects the referrer's full tier
  pending (0.0641 MOR at test scale; scales with referred stake × time);
  stranger control reverts.

## Technique note

After each `vm.warp`, only the external ChainLink aggregators'
`latestRoundData` is re-mocked with the **same answers** read at the pinned
block and a fresh `updatedAt` (a heartbeat republication, needed because the
protocol rejects stale feeds). No Morpheus contract is mocked.
