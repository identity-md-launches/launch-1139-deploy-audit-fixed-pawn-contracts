# FloorRelay, Setup and keeper handoff

The existing site name is **pawn.site.identitymd.eth**. Source is in `web/` and
its complete static export is in `dist/`. No on-chain deployment or transaction
is performed by this assignment. PawnShop, MilestoneBurn, PAWN, the existing
manifest, deployment addresses, dependencies and build settings are unchanged.

## Redeployment with audit e4a761c2 fixes

The redeployed PawnShop takes the **deployed FloorRelay** as its constructor `attester_`, and
MilestoneBurn takes it as `signer_`. The identity.md floor question hash
`0x71ed43868c5c61fe21b72bbbdcc09913d4952a113a393c526e49f3289edf4be1` is a constructor preset.
New loans start paused. Setup therefore shows the preset hash and the attester as done, and the
earlier **Switch attester to FloorRelay** step is removed. The remaining owner steps are:

1. Post a fresh floor using the request-id flow below, buying the answer with no consumer.
   The oracle's `questionHash` covers the request's block window, so each new request has a
   new hash. Before posting, call `approveQuestionHash(collection, hash)` with that request's
   hash (owner only, immediate, no loan cooldown); the governed pin and its 48-hour rotation
   stay as they are. Posting the hash of a request the owner has not approved is rejected.
2. Set MilestoneBurn's question with `setQuestionHashOnce`. The question must use a
   **24-hour time-weighted price**, and its answers are accepted for **at most 1 hour** after
   `issuedAt`. Because the hash is per request, set it only after seeing an answer at or above
   the milestone; if that answer is missed, the setter can re-pin with `replaceQuestionHash`
   until the burn has fired.
3. Fund the burn vault, then unpause new loans.

Any later question-hash write to a collection (`setQuestionHashOnce`, or an executed queued
rotation) closes new loans for that collection for **48 hours**. A queued deposit cap must be
executed within **7 days** of maturity, and the owner can cancel it with `cancelDepositCap()`.

### Keeper and public upkeep

- `markOverdue(id)` from a loan's due date books an expected loss against half the stored floor.
- `startAuction(id)` after due + 3 days needs a **fresh** floor, so post one first. The
  bounty, `min(0.002 ETH, principal/100)`, is not paid when the borrower calls it.
- `restartAuction(id)` once an auction has sat at its terminal price for 7 days (17 days after
  the start), or at any time after `writeOffAuction`. It needs a fresh floor.
- `markAuctionLoss(id)` and `writeOffAuction(id)` work as before.
- Auctions cannot be bought in the block that started them, nor when the vault no longer holds
  the NFT. Write such loans off instead.

The shipped keeper does not yet call `markOverdue` or `restartAuction`. Run them manually until it
does. See [AUDIT-FIXES.md](AUDIT-FIXES.md) for every fix.

## Request-id workflow

There are **no oracle purchase, approval, payment-signature or paid-order API
calls** in the site or keeper. Buy the question on
[explorer.imd.fun](https://explorer.imd.fun), then paste its **oracle request UUID**
(not a payment order id or transaction hash). The same flow appears in Setup,
Borrow's public Refresh floor and Oracle & burn. Each shows the exact question
with a copy button. The site only reads the public API's
`GET /oracle/requests/:id` and `GET /oracle/requests/:id/attestation`.

For the relay, buy with **no consumer**, domain `IdentityMD Oracle`, version
`2`, chain 1, verifying contract zero. Request a uint256 with public panel
sources, at least five members, quorum at least four and tolerance at most
500 bps. Any `validForSeconds` is accepted; the floor is fresh for the shorter of 26 hours
and the signed lifetime, so a 24-hour answer needs a daily refresh.
The floor question is:

> What is the current floor price, in wei, of the identity.md NFT collection at 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D on Ethereum mainnet, defined as the lowest active listing on OpenSea or Blur at the time of answering? Answer as a uint256 in wei.

The burn question is:

> What is the fully diluted market cap of the PAWN token (0x4f2bacee5f2e7ce3f48dfbd635d96e9a8fcbe478, Ethereum mainnet), computed as total supply times the spot price from its Uniswap v4 ETH pool, converted to USD at the current ETH price? Answer as a uint256 in USD with 18 decimals.

The site verifies the signature against the relay's pinned IMD attester,
domain, request UUID, question text, canonical question hash, chain, answer
type, panel consensus, age and expiry. It checks the signed hash against the
configured on-chain hash. If initially unset, only the owner (and, for burn,
the immutable question setter) can confirm the one-time hash transaction.
The signed question hash is shown in the transaction review. The site then
packs `abi.encode(attestation, imdSignature)` into the consumer's `signature`
argument, simulates and submits. It skips floors whose `issuedAt` is not newer.
Burn rechecks evidence immediately before simulation; it needs a nonempty
vault, a cap of at least $1M in 18-decimal USD units and `burned() == false`.
Deposits into the burn vault cannot be withdrawn and tokens sent after its
single burn stay stranded.

A floor bounty is a **0.001 ETH pull credit**, available at most once per
collection per rolling 24 hours if the reserve is funded. Claim it separately.
Anyone can post first, so buying an answer does not reserve its bounty. Posting
and claiming cost gas. A purchase may fail to reach consensus and spend its
price. The UI stores only the request id for resuming a poll; Stop waiting
stops further polling/prompts, not a transaction already sent.

## Constraints the relay does not change

The relay adapts only the EIP-712 domain. Its immutable IMD attester is
`0x5598aa9146215bc13eb26f2c692ad1461fd32982`, confirmed from the
[public API](https://api.imd.fun/oracle/requests?limit=1) on 2026-10-08.
If that key rotates, deploy a separately reviewed relay and use PawnShop's
48-hour rotation again. Consumers continue checking validity windows,
question hashes, quorum and replay rules. PawnShop requires strictly increasing
`issuedAt`; MilestoneBurn is a one-time operation, with no rolling newest-floor
state. Neither consumer source was changed.

The captured real floor request `62702d2a-1a38-4543-93cc-7ece5ac20a66` proves
zero-consumer signature verification, but its lifetime is **86400 seconds**.
It still fails PawnShop's existing 26-hour lifetime rule. Do not buy the
explorer's 24-hour default and expect the relay to extend it.

Canonical question hashes include the resolved window and definitions, not
just question text. New requests may have different hashes. Before enabling
borrowing or permanently pinning the burn hash, the operator must arrange
compatible requests with the oracle service. Floor hash changes require the
owner's delayed `queueCollection` / `executeCollection`; the burn hash cannot
be changed. This assignment cannot override those deployed constraints.

## Keeper and responsibilities

See [keeper/README.md](../keeper/README.md). Configure exact IDs in
`floorRequestIds` and `marketCapRequestIds`; there is no global discovery or
purchase logic. The shared browser/keeper verifier selects relay packing when
the current governed signer has the verified runtime. Simulations, profit
checks, `startAuction`, bounded scans and health alerts remain. Dry run is the
default. The operator supplies gas, new compatible request IDs, funded bounty
reserves, scheduling, RPC/API uptime monitoring and secure signing credentials.
The keeper never sets owner parameters or deploys contracts.

## Build, validation and publication

Use the existing locked web toolchain. No new dependencies were added; the
keeper runtime and static site bundle include their dependencies as ordinary
files and run without an install. Build steps are `forge build`,
`node tools/export-relay.mjs`, rebuild `keeper/runtime.mjs` as documented in
its README, then the existing web typecheck/tests/build/export validation.
Run `forge test`, `forge fmt --check` and `node --test keeper/tests/*.test.mjs`.
Golden packing bytes in `test/fixtures/site-packed-floor.json` are checked by
both JavaScript and Solidity; public signature vectors are committed for
offline conformance checks. See [relay validation](floor-relay-validation.md)
for test coverage and its limits.

Publish with `imd site publish dist --name pawn` using the existing authorized
host. Compare the live HTML, JS and pixel frog `pawn.svg` against the export's
SHA-256 inventory after publication. A successful local export is not evidence
that the hosted name changed. The publication result for this update is
recorded in `docs/frontend/floor-relay/publication.json`.
