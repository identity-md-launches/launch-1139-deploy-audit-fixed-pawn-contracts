# Pawn (PAWN)

Borrow ETH against an identity.md seat while its worker continues to participate in the IMD swarm. Lenders hold WETH-backed ERC-4626 shares. Loans have fixed principal and terms: there are no price-triggered liquidations, but an overdue seat can be auctioned. Project account: [@PawnIMD](https://x.com/PawnIMD).

## Audit e4a761c2 redeployment (this revision)

PawnShop (with its LendingPool, LockDiscount and new VaultFactory), the CollateralVault implementation and MilestoneBurn are redeployed with fixes F1–F16 and the new protocol-share split from audit job `e4a761c2-59b8-4c34-84fc-54fade5f665a` (commit `5086b57`). The PAWN token and FloorRelay stay as deployed. [docs/AUDIT-FIXES.md](docs/AUDIT-FIXES.md) has the full finding → fix → test table. In short:

| Finding | Fix |
| --- | --- |
| F1 | `startAuction` needs a fresh floor; no `buyAuction` in the block the auction started |
| F2 | `restartAuction(id)` after a write-off or 7 days at the terminal price, with a fresh floor |
| F3 | `buyAuction` reverts if the vault does not hold the collateral; `writeOffAuction` settles that case |
| F4 | Allowance released beyond the realised loss vests over 7 days; allowance may fall only while collateral is held |
| F5 | `markOverdue(id)` from the due date books `principal − min(principal, floor/2)` (never decreasing) |
| F6 | `pawn(collection, tokenId, termId, minPrincipal, maxFee)`; the site sends ±1% bounds |
| F7 | No auction bounty to the borrower; bounty = `min(0.002 ETH, principal/100)` |
| F8 | `submitFloor` rejects `fromBlock > toBlock` and windows that closed more than 7800 blocks ago |
| F9 | `reserveUsed[id]` is restored to the shortfall reserve first from late recoveries |
| F10 | Invariant formulas sum additions before subtracting |
| F11 | MilestoneBurn accepts answers at most 1 hour old |
| F12 | `executeDepositCap` has a 7-day execution window; `cancelDepositCap()` (owner) |
| F13 | Vault `isValidSignature` uses `holdsCollateral()` and returns `0xffffffff` instead of reverting |
| F14 | `buyAuction` rejects the loan's vault or collection as receiver |
| F15 | Any question-hash write (one-shot or queued rotation) disables new loans for 48 h; the constructor preset is exempt |
| F16 | Discount-module `release` is try/caught on repay, buy and write-off |
| Protocol share | Lenders keep 85%. Of the 15% protocol share, 50% fills the reserves while either is below target and 50% goes to the fee recipient; at target, 100% goes to the recipient |

**Deployment parameters for the redeployment.** `PawnShop(owner_ = $owner, token_ = 0x4f2bacee5f2e7ce3f48dfbd635d96e9a8fcbe478, weth_ = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, attester_ = <deployed FloorRelay>)`; `MilestoneBurn(token_, setter_ = $owner, signer_ = <deployed FloorRelay>, shop_ = $contract:PawnShop)`. Presets compiled in: identity.md question hash `0x71ed43868c5c61fe21b72bbbdcc09913d4952a113a393c526e49f3289edf4be1`, `newLoansPaused = true`, fee recipient and pool owner = owner. **The FloorRelay address is not in this job's deployment record and must be supplied by the deployment operator**. No placeholder is committed. `launch.json` is the earlier manifest, which the manifest step replaces.

**MilestoneBurn question.** The burn question must ask for PAWN's fully diluted market cap from a **24-hour time-weighted average price** (not spot), because an answer is accepted for only 1 hour after it is issued. Set it with `setQuestionHashOnce` after deployment, once an answer at or above the milestone exists; the setter can re-pin with `replaceQuestionHash` until the burn fires.

**Operational responsibilities added.** Keepers or anyone: `markOverdue` from each loan's due date, `startAuction` (after posting a fresh floor), `restartAuction` for stale auctions, `markAuctionLoss` and `writeOffAuction` as before. Owner: `cancelDepositCap` if needed. A queued cap must be executed within 7 days of maturity. After any question-hash rotation, new loans for that collection stay closed for 48 h.

**Site.** The source in `web/` and the ABIs in `web/public/abi` target the new interface: pawn slippage bounds, the Setup presets panel (the attester-switch step is removed), and Stats showing protocol fees to the recipient and the reserve levels. The address files (`web/deployment.json`, `web/public/imd-deployment.json`) and `dist/` still describe the live contracts. Refresh them from the post-deployment record, then rebuild and publish under `pawn.site.identitymd.eth`. Publishing the new site before the contracts exist would break borrowing.

## Website: install, preview, rebuild and publish

The existing React/TypeScript site is in `web/`; its complete static export is in `dist/`. Use Node.js 22.12+ and the committed `web/package-lock.json`:

```sh
npm ci --prefix web --cache /tmp/pawn-npm-cache
npm --prefix web run typecheck
npm --prefix web test
npm --prefix web run build
npm --prefix web run validate:export
npm --prefix web run preview
```

Preview serves the production export locally; `npm --prefix web run dev` serves source. Builds verify pinned ABIs and regenerate the exported asset inventory. Vite uses `base: './'` and hash routing, so serve the complete `dist/` directory at any static gateway subpath. Keep source, manifest, lockfile and export together in the submission; dependencies and caches are not deliverables.

Setup and governance transaction controls now render only for the relevant connected contract owner. All visitors can read paused/open state, deposit cap, floor question configuration and pending changes with countdowns in Governance. Direct non-owner `#setup` links show the same read-only state. The public Refresh floor flow and personal borrower/lender claims remain available under their existing rules. The pixel theme and frog assets remain. FloorRelay adds zero-consumer signature support without changing PawnShop or MilestoneBurn. Oracle purchases happen on the explorer; the site accepts request IDs and the keeper reads configured IDs.

To publish the export under the existing name, from an authorized IdentityMD host:

```sh
imd site publish dist --name pawn
```

The target remains **pawn.site.identitymd.eth**. This worker attempted that command, but the service refused it with **503 `member_sites_closed`: “this plane names no member sites”**. No new CID or name update was returned. Live delivery of this update’s assets and favicon could not be confirmed. See [the current publication record](docs/frontend/floor-relay/publication.json). An authorized hosting service must publish this export when naming is available. After publication, compare the served HTML/JS and `pawn.svg` with `dist/` and its `imd-deployment.json` SHA-256 inventory; do not treat a successful local build as publication.

Current FloorRelay validation and operational limits are recorded in [relay validation](docs/floor-relay-validation.md) and [Setup and keeper](docs/SETUP-AND-KEEPER.md). No on-chain transaction was signed or broadcast. Files are prepared for the submission system; git metadata is not modified.

This contribution contains contracts, local tests, vendored dependencies and ABI exports. The separate manifest contributor owns `launch.json`; independent review, source publication, admission, deployment and the IPFS frontend follow this contribution. No transactions are broadcast by this repository.

## Build and test

```sh
forge build
forge test
forge fmt --check
python3 tools/export_abis.py
```

Solidity **0.8.26**, Cancun, optimizer 200 runs, via IR, no metadata hash or CBOR footer. FFI and filesystem cheatcode permissions are not enabled. OpenZeppelin **5.5.0** and forge-std **1.9.7** are vendored as ordinary files; no network or submodules are needed to build. The version-pinned compiler is supplied by the verifier. Tests use local ERC-721/WETH fixtures and explicit configuration, never an RPC, wallet key, environment variables or broadcasts. Test keys occur only in `test/`.

The tests include the supplied oracle digest/signature vector, success and rejection paths, rounding fuzz tests, deployment/opcode checks and stateful conservation/custody invariants. These checks are not an independent security audit. See [review notes](docs/review-notes.md) for specific requirement conflicts and launch considerations.

The revision includes regression tests for the review findings and the supplied proof cases; [validation details](docs/validation.md) record the final commands, scope and runtime sizes.

## Contracts and deployment parameters

| Contract | Constructor arguments | Deployment |
| --- | --- | --- |
| `FloorRelay` | none | Kept as deployed; its address is PawnShop's `attester_` and MilestoneBurn's `signer_` |
| `LaunchToken` | none | Launch token; manifest token identifier `LaunchToken` |
| `PawnShop` | `address owner_, address token_, address weth_, address attester_` | Application; `$owner`, `$token`, Ethereum WETH below, the deployed FloorRelay |
| `VaultFactory` | none | Created inside `PawnShop`'s constructor; discover with `vaultFactory()`; only the shop can create vaults |
| `LendingPool` | `address owner_, address weth_, address shop_` | Created and configured inside `PawnShop`'s constructor; discover with `lendingPool()` |
| `LockDiscount` | `address token_, address shop_` | Created and configured inside `PawnShop`'s constructor; discover with `discountModule()` |
| `CollateralVault` | `address shop_` | One standalone instance per `pawn()`, created through VaultFactory and initialized atomically by PawnShop |
| `MilestoneBurn` | `address token_, address setter_, address signer_, address shop_` | Application after PawnShop; `$token`, `$owner`, supplied oracle signer below, `$contract:PawnShop` |

The manifest should list **PawnShop and MilestoneBurn** as its two application deployments, after the token. Pool and discount are constructor-created children with their shop permanently set; listing them again would deploy unrelated duplicates. A vault is created only when there is collateral. All constructors are nonpayable and use supported static argument types. No constructor takes or redistributes any of the launch token supply. Children and per-loan vaults also have exported ABIs and need source verification and indexing after deployment. Constructor arguments are explicit; control never defaults to the launch factory's `msg.sender`.

| Ethereum mainnet parameter | Value / authority |
| --- | --- |
| Chain | 1 |
| Intended owner and burn question setter | `0x23e5d7a7b4ea19530ec39c67cd46aa8c10d15acf`, from the workflow; manifest `$owner` must resolve to this address |
| Identity collection | `0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D`, from the workflow |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`, from the workflow |
| Initial attester for both consumers | `0x5598aa9146215bc13eb26f2c692ad1461fd32982`, supplied protocol reference; confirmed by [oracle API](https://api.imd.fun/oracle/requests?limit=1) on 2026-10-08 |
| Floor and burn question hashes | Unconfigured storage at launch; set to actual oracle canonical hashes after launch, never fabricated constructor values |

The identity collection is initially enabled with 40% floor LTV for both terms and a 100% collection share limit. New loans are **paused** initially. Mainnet addresses are supplied inputs, not invented test deployment addresses. Deployment services must check the intended network and verify live code; local tests do not claim to have fork-tested mainnet.

**Launch token:** Pawn / PAWN, 18 decimals, exactly 1,000,000,000 tokens minted to its deployer. No mint, owner, pause, tax, blocklist or upgrade functions. The factory allocates supply and creates the launch trading pool. Application contracts neither seed that pool nor implement swap fees. The owner can claim its protocol trading income and voluntarily forward ETH to `LendingPool.donate()`. The network's trading fee comes from LaunchFees (1.25% in the supplied policy); a manifest fee of 3000 is not a claim that the trading pool charges 0.3%.

## Borrowing and repayment

1. Approve PawnShop for the seat. Optionally approve and lock PAWN in LockDiscount first.
2. Call `pawn(collection, tokenId, termId, minPrincipal, maxFee)`; it reverts `Slippage` if the principal is below `minPrincipal` or the fee above `maxFee` (the site sends the displayed principal −1% and fee +1%). New loans for a collection are closed for 48 hours after any question-hash write (constructor preset exempt). Term 0 starts at 30 days / 300 bps; term 1 at 7 days / 100 bps. Principal is always the configured term's maximum floor percentage, rounded down. There is no smaller-amount argument or automatic reduction to available liquidity; an oversized loan reverts. Minimum principal is 0.01 ETH. The collection's outstanding principal plus this loan must fit its share of `pool.totalAssets()`, and enough idle WETH must exist.
3. PawnShop creates a vault, takes the NFT and credits principal minus the discounted fee. Call `PawnShop.claim(receiver)` to receive the ETH.
4. Any payer can `repay(loanId)` with exactly the full principal until an auction starts, including after expiry. If the vault still owns the NFT, it returns to the recorded borrower. Collection revocation, seizure or burning does not block repayment or PAWN commitment release; a missing NFT cannot be returned. There is no early repayment fee rebate.
5. Only the borrower can `extend(loanId, termId)` with exactly the discounted fee and a fresh floor. The new due date is `max(oldDue, now) + chosenDuration`. Both term choices are snapshotted at origination, so later term changes do not alter an existing loan. A module change applies only to new loans: each loan uses and eventually releases its original module. Extensions have no LTV recheck, count limit or maximum future due date; even underwater loans can extend repeatedly while paying the fee and posting a fresh floor. Lenders cannot force resolution while such extensions continue.

Pausing or disabling a collection blocks new loans only. Extensions, repayments, lender withdrawals, claims, token unlocks and auctions remain available subject to their own conditions. An extension after maturity is possible until someone starts the auction. The first mined transaction wins that race.

Fees are calculated with ceiling rounding; module output is capped at the undiscounted fee. Of each fee, 15% rounded down is protocol income and the remainder (at least 85%) vests into lender assets over seven days. This prevents a same-block deposit and withdrawal from capturing the upfront fee. The vesting period is not a lock for the entire loan term. While either reserve is below target, half of the protocol income fills them, in this order, and the other half is a pull credit for the fee recipient (initially the owner). Once both are at target, all protocol income goes to the fee recipient:

- The shop's bounty reserve to 0.2 ETH.
- The pool's shortfall reserve to 5% of its current total assets, excluding that reserve.

`protocolFeesToRecipient()` and `protocolFeesToReserves()` hold the running totals.

No owner function withdraws reserves, pool assets, NFTs, borrower proceeds, locked PAWN or burn-vault tokens. Fee credits belong to the recipient at the time earned; changing the recipient cannot redirect existing credits.

## Lenders, reserves and donations

LendingPool is OpenZeppelin ERC-4626 over WETH, with a six-decimal virtual share offset (share decimals **24**, asset decimals **18**). Standard `deposit`, `mint`, `withdraw` and `redeem` use WETH. `depositETH(receiver)` wraps native ETH; `withdrawETH(assets, receiver, owner)` and `redeemETH(shares, receiver, owner)` unwrap and credit the recipient, who then calls `claim(receiver)`. Spending another account's shares requires a share allowance. Do not confuse 24-decimal pETH shares with 18-decimal ETH or PAWN.

```text
totalAssets = WETH balance + outstanding principal
              - max(shortfall reserve, expected auction loss) - unvested income
idleAssets  = WETH balance - shortfall reserve - unvested income
```

Only PawnShop can borrow, mark expected auction losses or settle principal. `totalBorrowed` is gross principal until settlement or write-off; `expectedAuctionLoss` is the separate loss allowance. `unvestedDonations()` includes donations, loan fees and late recoveries for ABI compatibility. Withdrawals cannot use outstanding loans, unvested donations or reserves. The initial deposit cap is 10 ETH of `totalAssets`; interest, direct transfers and vesting may take assets above the cap, in which case new deposits stop until there is room or a cap increase takes effect. The cap can only rise, with a 48-hour delay. Withdrawals have no queue or priority guarantee: first-come withdrawals depend on idle liquidity.

Anyone can `donate()` with ETH while actual lender shares exist; with zero share supply it reverts. Every donation, loan fee and late recovery vests linearly for exactly seven days from its timestamp. Fee or recovery income arriving with no shares is classified as shortfall reserve. When the final actual share is burned, any remaining idle WETH (including unvested streams and rounding dust) becomes reserve and those streams are retired. This prevents empty-pool income from being stranded in the virtual-share offset; that money backs future losses, not an administrator withdrawal. Cumulative checkpoints and binary search avoid unbounded scans, dust resets and fixed queue exhaustion. Unvested amounts round up to the next wei; they cannot be borrowed or withdrawn. Donors receive no shares and cannot recall donations. A direct WETH transfer bypasses vesting; use `donate()` for the intended behavior. The virtual share offset mitigates donation inflation attacks, but direct transfers can still change share prices. Integrators should use preview methods and appropriate transaction-level amount checks.

Starting an auction records principal minus its maximum current recovery as an expected loss. The share price deducts only the portion exceeding the shortfall reserve, so already-recognised gaps are shared before a lender exits. `markAuctionLoss(loanId)` is permissionless on PawnShop and refreshes the allowance as the Dutch price falls or collateral disappears. Actual settlement removes that loan's allowance, consumes reserves first and increments `cumulativeLoss` only for the realised uncovered gap; it does not charge the same loss twice. Loan-level allowances share a single reserve, without allocating it twice. Unvested donations stay segregated. Reserves do not protect against every loss and are never a guaranteed return.

## Defaults, auctions and bounties

Anyone may call `markOverdue` from the due date to book an expected loss against half the stored floor. Anyone may call `startAuction` strictly after `due + 3 days`, and only while the floor is fresh. It freezes that floor and credits a bounty of `min(0.002 ETH, principal/100)` when enough bounty reserve exists. The borrower gets no bounty. An auction cannot be bought in the block it started, nor once the vault no longer holds the NFT (write it off instead), and the receiver cannot be the vault or the collection. `restartAuction` re-runs the curve from a fresh floor after a write-off or after 7 days at the terminal price. Once started, the loan cannot be repaid or extended. The price declines continuously, with ceiling rounding:

| Elapsed time | Price |
| --- | --- |
| Start | 100% of captured floor |
| First 72 hours | Linear decline to 70% |
| Next seven days | Linear decline from 70% to 50% |
| Ten days onward | Holds at 50% |

`buyAuction(loanId, receiver)` accepts ETH at least equal to the current price. Principal recovery goes to the pool; surplus goes to the borrower; overpayment goes to the buyer. Both surplus and overpayment are pull credits. LockDiscount releases the commitment and the NFT transfers to the chosen receiver. NFT transfers use `transferFrom` on exit to avoid a receiver callback blocking resolution; buyers must select an address able to manage the NFT. A transfer that fails while the vault still owns the NFT rolls the whole sale or repayment back. If `ownerOf` reports another owner or reverts (including a burned id), the vault skips delivery, clears worker authority and emits `CollateralUnavailable`. Such an auction is priced at zero, so anyone can settle it without funding a fictitious purchase; any sent ETH is credited back to the buyer. Collection ownership reporting remains a trust assumption.

After **40 days from auction start** (30 days holding at 50%), anyone may `writeOffAuction(loanId)`. Missing collateral permits this immediately after auction start. The pool settles the unpaid principal at zero, using reserves first, and collection debt and the PAWN commitment clear. The seat stays in its vault and remains for sale at the original auction curve; write-off grants no free collateral or owner rescue. A later sale sends up to the original principal to the pool as a seven-day recovery stream, tracked by `cumulativeRecoveries`; surplus still belongs to the borrower. Repeat write-offs revert. Even a collection that currently rejects transfers cannot block this financial write-off. A malicious discount module can still block its own release call.

Keepers and lenders must call `markAuctionLoss` as prices decline and `writeOffAuction` for dead auctions. Accounting does not scan every auction during share operations or automatically mark debt just because time passed. Before those calls, later price declines or unsaleability may remain unrecognised, and an earlier withdrawal may avoid that additional loss. Active loans also remain at principal. The launch does not promise continuous market-value accounting or guaranteed recovery.

Anyone may `fundBounties()` with ETH; these contributions are nonrefundable. Insufficient bounty reserves skip the bounty and never block floor submission or auctions. The first valid floor update per collection per rolling 24 hours earns 0.001 ETH when funded. An unfunded first update still consumes that interval. Keepers compete for these credits; no gas-cost reimbursement is guaranteed. Signatures are not bound to a submitter: someone can copy a pending floor transaction, submit it first, take the bounty, and make the original payer's transaction revert. Auction-start bounties have the same first-mined race. Oracle payment does not confer bounty ownership; keepers may use private transaction delivery but no privacy guarantee is provided.

## PAWN locks and worker operation

| PAWN locked at pawn/extension | Fee reduction | PAWN committed |
| --- | --- | --- |
| 1,000,000 | 2,000 bps (20%) | 1,000,000 |
| 5,000,000 | 3,333 bps (33.33%) | 5,000,000 |
| 20,000,000 | 5,000 bps (50%) | 20,000,000 |

The largest open commitment is locked, rather than the sum. Excess PAWN can be unlocked immediately. On extension, the loan's commitment is refreshed from the current locked balance; on repayment, auction settlement or financial write-off it is released. Three tier counters give constant-bounded lookup even for many loans. LockDiscount has no owner or asset rescue path. Accidental direct token transfers to it do not create lock credits.

The vault's ERC-1271 implementation recognizes only the borrower's current registered **WorkerAuthorization** digest. Its exact schema was checked against [IMD's pairing page](https://api.imd.fun/pair) on 2026-10-08:

```text
domain: name="IdentityMD Worker", version="2", chainId=current chain,
        verifyingContract=the NFT collection
WorkerAuthorization(bytes32 deviceKey,address wallet,uint256 tokenId,bytes32 nonce,uint64 expiresAt,string relayOrigin)
```

Use the pairing service's real device key, nonce and relay origin. `wallet` must be the **vault address**, which owns the seat; `tokenId` must be the loan's seat. The borrower calls `vault.authorizeWorker(message)`. An ERC-1271 client can then use an empty signature with that exact digest. Generic signing, sell-order hashes and permit hashes are refused. Registration expires with the message, can be replaced or revoked by the borrower, and becomes invalid at auction start or loan closure. The worker service must check ERC-1271 and current ownership when authenticating; this repository does not claim that an existing off-chain enrollment is automatically removed by a Solidity event.

While the loan is active the borrower may use `callFor(target,data)` without ETH value to claim rewards. Direct calls to the collection, shop, pool or vault are blocked, and NFT ownership is checked afterwards. The borrower can withdraw vault ERC-20 rewards and queue/claim vault ETH even after loan closure. A vault never approves its collateral. An unsolicited NFT sent with plain `transferFrom` cannot be recovered; safe transfers accept only its assigned collateral from PawnShop.

## Oracle operations and burn

Both consumers use the supplied **OracleAttestation v2** library unchanged. EIP-712 domain: `IdentityMD Oracle`, version `2`, current chain ID, verifying contract **the particular consumer**. The application requires `a.chainId == 1`, a pinned question hash, uint256 answer in wei (floor) or USD with 18 decimals (FDV), panel size at least five, quorum at least four, agreement at least quorum and no greater than panel size. It rejects future timestamps, attestations older than 26 hours, expired signatures and reused request IDs. Floor updates must be strictly newer than the collection's stored timestamp and expire after they were issued; any signed lifetime is accepted (the service issues 24-hour floors) and the floor is fresh for the shorter of 26 hours and the signed lifetime. Longer lifetimes do not veto later answers, and no answer is used past its signed expiry or the 26-hour age limit. Because the oracle's `questionHash` covers each request's block window, the owner admits each floor request's hash with `approveQuestionHash` before it is posted (see ADAPTATION.md). Lending stops after the 26-hour age bound; changing the configured question also invalidates freshness until a new matching answer is accepted.

These are permissionless signed submissions, not contracts that buy oracle requests or receive Intake callbacks. Operators pay the oracle outside the application and submit the returned attestation to `submitFloor(collection,a,signature)` or `burn(a,signature)`. Before relay activation, a signature for the shop cannot trigger a burn. After activation, the relay translates the same authentic zero-consumer attestation into either caller’s domain; each consumer still checks its own configured question and policy. The constructor requires the real nonzero signer supplied above; the canonical verifier rejects zero signers. PawnShop signer rotations take 48 hours. MilestoneBurn binds to PawnShop in its constructor and validates the initial token and signer match. Anyone can `syncSigner()` after a shop rotation; `burn()` always synchronizes before verification, so a retired signer cannot race that explicit sync. The burn vault acquires no owner or withdrawal function, but trusts the shop's governed signer choices.

MilestoneBurn accepts voluntary PAWN transfers. Once the signed FDV reaches **1,000,000 × 10^18 USD units**, anyone may burn its entire current balance by transferring it to the expressly requested `0x000000000000000000000000000000000000dEaD`. This is a one-time sink transfer, not ERC-20 supply reduction. Empty burns revert. PAWN sent after the burn stays trapped forever, so check `burned()` before sending. There is no withdrawal, rescue, owner or second burn. Its question setter can configure the hash once and has no other power. The one-shot hash still has the window compatibility limitation below; signer rotation alone does not solve that issue.

## After launch

- Deployment operator: deploy and verify `FloorRelay` on mainnet with no arguments, then give its address to the owner. This assignment deploys nothing and supplies no guessed relay address. Owner: use Setup’s **Switch attester to FloorRelay**, wait 48 hours and execute within the following 7 days. MilestoneBurn follows PawnShop automatically. The immutable relay pins chain 1 and IMD’s published attester; future key rotation requires another relay and governed switch. See [the complete activation procedure](docs/SETUP-AND-KEEPER.md).

- Owner: call `PawnShop.setQuestionHashOnce(identityCollection, actualHash)`. Obtain the canonical hash from the oracle's attestation API after agreeing an unambiguous floor question, chain, window and definitions. Do not use a locally invented hash. Collection changes, including later hash rotations, use `queueCollection` / `executeCollection` with a 48-hour delay.
- Original owner / immutable `questionSetter`: call `MilestoneBurn.setQuestionHashOnce(actualHash)` with the canonical PAWN FDV question hash. Check the actual deployed PAWN address, USD units, supply convention and pricing method before consuming this one-time setting.
- Oracle operator: buy compatible collection floor and PAWN FDV questions on explorer.imd.fun. After the FloorRelay switch, omit the consumer; before it, request the relevant consumer domain. Paste the returned UUID on the site or configure it in the keeper. The supplied Ethereum Intake is `0x1397434cd35e8a9c8ac312a61d3a285eb31dea56`, payment asset IMD is `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, and the supplied action is the right-padded text `oracle.request@oracle-1`. The supplied price is 0.5 IMD; query the live service or `priceOf` before paying. Top up that operator wallet, **not** the shop or burn contract. Refused or inconclusive requests can spend the price without yielding an attestation. Oracle payments are not refunded by Pawn.
- Owner and oracle operator: resolve the canonical question-hash/window issue in [review notes](docs/review-notes.md) before enabling borrowing. The hash pins the resolved window as well as the question; do not assume a new relative-window answer will reuse it.
- Anyone: fund lender liquidity with `deposit` / `depositETH` and optionally keeper reserves through `fundBounties`. Owner: submit a valid floor, check all setup and then call `setNewLoansPaused(false)`.
- Keepers/lenders: monitor auction prices and collateral availability, call `PawnShop.markAuctionLoss(loanId)` to keep loss allowances current, and call `writeOffAuction(loanId)` after 40 days unsold (or earlier if collateral is missing). These maintenance calls pay no extra bounty. Later auction sales remain possible.
- Owner: claim protocol trading income through the launch's deployed pool flow and forward desired ETH through `LendingPool.donate()` while `totalSupply() > 0`; otherwise retain it in the claiming wallet until lenders arrive. This is a voluntary operational responsibility, not an automatic token tax.
- Frontend/deployment services: discover constructor-created children, index events and per-loan vaults, publish the actual deployment addresses and use the exact trading `poolKey` in the handoff. This repository contains no guessed application addresses.

## Governance and risks

PawnShop and LendingPool have independent OpenZeppelin Ownable2Step ownership, explicitly initialized to the intended owner. Transfer/accept ownership on both when rotating operations. Renunciation is disabled. LockDiscount and MilestoneBurn have no ongoing owner, and vault control is limited to the borrower and immutable PawnShop.

PawnShop's immediate powers are pausing/unpausing new loans, disabling new borrowing for a collection, setting an unset collection hash once, and cancelling a queued change. Changes to terms, collection limits/status/question, attester, fee recipient and discount module wait 48 hours. Anyone can execute the exact queued payload from its 48-hour deadline through the following seven days, inclusive. A newer queue supersedes the older payload for the same setting (each term id and collection has its own setting); disabling a collection cancels its pending collection change. Expired payloads must be queued anew and wait another 48 hours. Terms are restricted to 7–90 days and 50–1,000 bps; LTV cannot exceed 4,000 bps; non-seat collection share cannot exceed 2,500 bps. The pool owner can queue only increases to its deposit cap, also delayed 48 hours. Economic constants such as fee split, bounty amounts, grace period and auction slopes are immutable; there is no generic arbitrary-call governance function.

Lenders trust the oracle attester's correctness, the collection's ownership/transfer implementation, and governance's future collection and module selections. The immediate one-shot question selection and the delayed attester/collection powers can economically expose **all idle lender ETH**: an unsuitable question with a genuine large answer, a malicious signer (including ERC-1271), or worthless owner-listed collateral can support a loan sized to the available liquidity. Values above the collection share ceiling revert rather than being clamped, but a tailored valuation can still borrow the entire idle balance. Absence of an explicit owner withdrawal is not protection from those valuation powers. Monitor 48-hour queues; initial question selection has no delay. Signer governance also controls which signatures the burn vault accepts. A malicious replacement module can impair new loans using it; it cannot change existing loans' stored module. The reserve can be exhausted; unsold collateral, a bad or stale auction floor, collection transfer restrictions or a failing oracle can prevent timely recovery. Worker enrollment and reward-service compatibility are external dependencies. Transactions can be reordered and auction purchases can compete. ETH credits remain claimable if a chosen receiver rejects ETH; retry with a different receiver. Forced ETH transfers are not counted as lender assets or administrator income and have no rescue path.

The contract/source conflicts documented for independent review are part of this handoff; passing tests do not resolve them or constitute launch approval.


The owner Setup page, night theme and keeper update are documented in [the operating handoff](docs/SETUP-AND-KEEPER.md). The installable hourly workflow and cron live in [keeper/](keeper/README.md). The static export continues to target `pawn.site.identitymd.eth`.
