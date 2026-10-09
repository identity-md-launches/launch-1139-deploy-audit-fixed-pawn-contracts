# Launch adaptation: Pawn on Ethereum mainnet (evm_contracts)

This records every change made to launch the audit-fixed Pawn contracts through the `evm_contracts`
factory, the rule or audit finding that required each one, and the audit findings that were not
changed and why. The manifest (`launch.json`) is written by the manifest step; it is not in this tree.

## Deployment order and constructor arguments

The factory deploys, in this order, with `$owner` the wallet that paid for the launch:

| # | Contract      | constructorArgs                                                                                                   |
|---|---------------|--------------------------------------------------------------------------------------------------------------------|
| 1 | FloorRelay    | `[]` (IMD attester `0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982` and chain 1 are constants in source)              |
| 2 | PawnShop      | `["$owner", "0x4f2bacee5f2e7ce3f48dfbd635d96e9a8fcbe478", "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", "$contract:FloorRelay"]` |
| 3 | LockDiscount  | `["0x4f2bacee5f2e7ce3f48dfbd635d96e9a8fcbe478", "$contract:PawnShop"]`                                             |
| 4 | MilestoneBurn | `["0x4f2bacee5f2e7ce3f48dfbd635d96e9a8fcbe478", "$owner", "$contract:FloorRelay", "$contract:PawnShop"]`           |

PawnShop's constructor presets the identity.md collection with question hash
`0x71ed43868c5c61fe21b72bbbdcc09913d4952a113a393c526e49f3289edf4be1`, sets `newLoansPaused = true`,
makes `$owner` the fee recipient and the LendingPool owner, and creates three children with its own
address: `LendingPool` (read it from `PawnShop.lendingPool()`), `VaultFactory` (`vaultFactory()`) and
the bound `LockDiscount` (`discountModule()`). Collateral vaults are standalone contracts created per
loan by `VaultFactory`; there is no implementation-plus-clones pattern (clones would need DELEGATECALL,
which the launch forbids), so there is no "CollateralVault implementation" address to record.

MilestoneBurn's constructor takes four arguments, not two: the brief's "token, PawnShop" reading does
not encode (audit finding 74244bd9). The third argument must be the shop's initial attester
(`$contract:FloorRelay`); `burn` always re-reads the shop's governed signer, so this value only has
to be a nonzero address at deployment. The setter (`$owner`) is immutable and can only pin the question.

The standalone `LockDiscount` from step 3 is *not* the shop's discount module until the owner binds it
through `queueDiscountModule` / `executeDiscountModule` (48 h). The records must publish
`PawnShop.discountModule()` as the discount module (audit finding 30e78fa4; see below).

Test: `test/LaunchAdaptation.t.sol::test_launchOrderDeploysOnEmptyChainWithFactoryAsSender` deploys
this exact sequence with the factory as `msg.sender` on a chain where the token and WETH have no code,
checks owner/attester/fee-recipient wiring, and walks every runtime (including the children) for size
and the forbidden opcodes.

## Changes required by the launch rules

1. **`src/MilestoneBurn.sol` constructor no longer calls PawnShop.** The launch rehearses constructors
   on an empty chain and forbids a constructor that calls another contract. The former constructor
   read `pawnToken()` and `oracleSigner()` from the shop and reverted on mismatch. The token binding
   is now checked on first use in `burn` (reverts `Unauthorized` if the shop's token differs), and the
   signer is read from the shop by `syncSigner()` on every burn as before. A zero shop address is
   still refused. Tests: `test/MilestoneBurn.t.sol::test_constructorNeedsNoLiveShopAndBurnChecksItLater`,
   `test_unrelatedSignerIsReplacedAndWrongTokenIsRefusedOnFirstUse` (replaces
   `test_deploymentRejectsUnrelatedSignerSource`, which encoded the constructor-time check).

2. **`launch.json` removed.** The committed file was the previous `evm_project` manifest (token
   block, pool block, `$token`, raw EOA attester) and is invalid for an `evm_contracts` launch; a
   manifest left in the tree is checked as one and would reject this work (audit finding aa1615b5).
   The manifest step writes the new one from the table above.

No other launch rule needed a change: every contract is configured in a nonpayable constructor with
static argument types, no contract uses an initializer, proxy, DELEGATECALL, CALLCODE or
SELFDESTRUCT, no owner is `msg.sender`, there is no launch token to add, and the project's
`foundry.toml` already uses `bytecode_hash = "none"`.

## Audit findings that reproduced and were fixed

3. **[high] da7976ab — the pinned question hash can never admit a live floor.**
   Reproduced by reading the oracle API: `questionHash` covers each request's block window, so every
   fresh floor request carries a new hash, the exact pin rejects it, and the governed rotation path
   (48 h timelock, then a 48 h loan cooldown, against a 26 h maximum answer age) can never bring a
   fresh answer into use. The one matching request is also permanently out of its block window.
   Change (`src/PawnShop.sol`): `approveQuestionHash(address collection, bytes32 hash)` (owner only,
   immediate, no loan cooldown) records `approvedQuestionHash[collection]`; `submitFloor` accepts an
   answer whose hash equals either the governed pin or the approved hash. Every other rule still
   applies to the admitted answer (chain, panel, quorum, age, block window, signature through the
   attester, single use of the request id, strictly newer `issuedAt`). Approval requires the
   collection's governed question to be configured, and an executed rotation of the governed
   question clears it. The preset hash, the one-shot setter, the queue/execute rotation and the F15
   cooldown are untouched.
   Trust assumption (state it in the review): the owner vouches, per request, that the request asks
   the configured question. The owner could previously reach the same outcome in 48 h through
   `queueAttester`/`executeAttester` (audit info finding cbd47c4c); this path removes that delay for
   floor admission only. Lenders see `QuestionHashApproved` events. The alternative of pinning a
   window-independent hash does not exist in the oracle, and a cooldown on approval reproduces the
   dead end. If the requester prefers a delayed approval, the delay must be shorter than the 26 h
   freshness window; that constant is theirs to choose.
   Tests: `test/LaunchAdaptation.t.sol::test_ownerApprovedRequestHashAdmitsFreshFloorWithoutCooldown`,
   `test_approvedHashStillObeysEveryOtherFloorRule`, `test_governedRotationClearsTheApproval`.
   Site/keeper: `web/src/oracle-flow.tsx` validates evidence against the approved hash when it matches,
   and the mismatch message in `web/src/oracle.ts` names `approveQuestionHash`.

4. **[medium] bf57e268 — written-off auctions could be restarted every block.**
   Reproduced: `restartAuction` skipped the `RESTART_AFTER` interval once `writtenOff[id]` was true,
   so a free restart in every block reset the price to the full floor and made every purchase revert
   with `SameBlock` or `IncorrectPayment`. Change (`src/PawnShop.sol`): the 17-day interval now
   applies to every restart. A write-off happens at least 40 days after the auction start, so the
   first restart after a write-off is still allowed immediately. Tests:
   `test_writtenOffAuctionCannotBeRestartedEveryBlock` (buyer pays the decayed price, recovery
   reaches the pool), `test_writtenOffRestartAllowedAgainAfterInterval`; the existing
   `test_F2_restartAfterWriteOffRoutesProceedsThroughRecovery` still passes.

5. **[medium] 0ac9b173 — a deposit during a release stream captured the release.**
   Reproduced with the audit's numbers (1 ETH lender, two 0.5 ETH loans, floor to 0.2 ETH, both
   marked overdue, one repaid, a sniper deposits `maxDeposit`): the sniper's shares were worth more
   than paid after seven days and the lender's recovered far less than their released allowance.
   Change (`src/LendingPool.sol`): `previewDeposit` and `previewMint` price entries on
   `totalAssets() + unvestedRelease()`, i.e. as if the release had already vested; `maxMint` follows
   `previewDeposit`. Redemptions keep the vesting price, so the unvested part can be neither bought
   nor withdrawn early. Without an active release stream the pricing is unchanged. Fee and donation
   streams are untouched: they are income earned over the holding period, not the reversal of a loss
   borne by specific holders. Tests: `test_depositDuringReleaseStreamCapturesNoneOfTheRelease`,
   `test_depositPricingUnchangedWithoutAnActiveReleaseStream`; the pool invariant suites pass.

6. **[low] 56506f8c — the service's 24-hour floor answers were refused.**
   Reproduced with the audit's proof (now `test/LiveFloorLifetime.t.sol`): the only authentic
   identity.md floor attestation verifies through FloorRelay but `submitFloor` demanded a signed
   lifetime of at least 26 h. Change (`src/PawnShop.sol`): any `expiresAt > issuedAt` is accepted;
   `floorFresh` already bounds freshness by the shorter of 26 h and the signed expiry, and a signed
   expiry is never extended. Three existing tests encoded the removed rule and were rewritten to
   assert the retained property (a floor is never fresh past its signed expiry):
   `test/FloorRelay.t.sol::test_realFloorWithTwentyFourHourLifetimeIsAccepted`,
   `test/Oracle.t.sol::test_floorIsNeverFreshPastItsSignedExpiry`,
   `test/ReviewRegression.t.sol::test_shortExpiryFloorStopsLendingAtItsSignedExpiry`. The matching
   client-side rule was relaxed in `web/src/oracle.ts` and in the bundled keeper verifier
   `keeper/runtime.mjs`; `README.md` and `docs/SETUP-AND-KEEPER.md` no longer ask for
   `validForSeconds >= 93600`.

7. **[low] c079051d — MilestoneBurn's one-shot hash could strand the vault's PAWN.**
   Reproduced: the hash is per request, the setter had no second write and there is no withdrawal.
   Change (`src/MilestoneBurn.sol`): `replaceQuestionHash(bytes32)` lets the immutable setter re-pin
   until the burn has fired. `setQuestionHashOnce` keeps its first-write semantics so the site flow
   and existing tests are unchanged. The setter still cannot move funds; burning is the only effect
   and it was already in the setter's power at the first write. Test:
   `test/MilestoneBurn.t.sol::test_setterMayRepinUntilBurned`. `docs/SETUP-AND-KEEPER.md` now says to
   pin only after an answer at or above the milestone exists.

8. **[low] 74244bd9 — deployment plan mismatch for MilestoneBurn.** Reproduced; resolved by the
   four-argument manifest entry above and by change 1 (no constructor-time shop call).

9. **[low] aa1615b5 — committed launch.json was the previous evm_project manifest.** Reproduced;
   resolved by change 2 and the manifest table above (FloorRelay first, passed as the attester, so
   the zero-consumer answers verify from the first block).

## Audit findings not changed

- **[low] 30e78fa4 — a separately deployed LockDiscount is not the shop's module.** Reproduced: the
  brief's step 3 instance passes `_validateModule` but is unused until governed in. Not changed in
  source: PawnShop keeps creating and binding its own module in the constructor (removing that would
  leave `pawn()` unusable until a 48 h module change and alter the launch-time state the site reads),
  and the factory cannot bind a later deployment into an earlier one. The deployment handoff must
  record `PawnShop.discountModule()` as the discount module and list the step-3 instance only as a
  spare that the owner may bind later. The launch-order test asserts the two differ.
- **[info] cbd47c4c — owner trust assumptions.** Documented, not a defect. In addition to the listed
  powers, the owner now admits floor request hashes immediately (change 3).

## Records, verification and the site

Addresses are produced by the deployment service; nothing here invents them. `web/deployment.json`,
`web/public/imd-deployment.json`, `dist/imd-deployment.json` and `keeper/config.json` still carry the
previous launch's addresses and are replaced by the deployment handoff, which must record FloorRelay,
PawnShop, LockDiscount, MilestoneBurn and the children `PawnShop.lendingPool()`,
`PawnShop.vaultFactory()` and `PawnShop.discountModule()`, verify the sources on Etherscan, and
rebuild and publish the site (`dist/`) against them. The audit-fixed ABIs are regenerated in
`docs/abi/` and `web/public/abi/` (`python3 tools/export_abis.py` after `forge build`).

## Checks run

`forge build` and `forge test` with the project's own configuration: all suites pass, including the
fuzz and stateful invariant suites. The protected `evm_contracts` floor needs the deployment
service's environment and is mirrored locally by the launch-order test above.
