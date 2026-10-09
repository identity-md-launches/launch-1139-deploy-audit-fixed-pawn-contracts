# Pawn (PAWN)

Borrow ETH against an identity.md seat while its worker continues to participate in the IMD swarm. Lenders hold WETH-backed ERC-4626 shares. Loans have fixed principal and terms: there are no price-triggered liquidations, but an overdue seat can be auctioned. Project account: [@PawnIMD](https://x.com/PawnIMD).

## Mainnet site update — launch 1139

The site targets the latest `evm_contracts` launch on Ethereum mainnet (chain ID **1**), source commit `f6f7d1e5b521a0490732b996bb2c54473bd5f68f`. The existing name remains **pawn.site.identitymd.eth**. This assignment updates frontend source, deployment records, keeper addresses and the complete static export; it does not deploy or change contracts or re-mint PAWN.

| Contract | Verified mainnet address | Source |
| --- | --- | --- |
| FloorRelay | `0x1ff0fb56f9a6c5c5c8201906d487ec4d8f5afc50` | Launch 1139 |
| PawnShop | `0xf0d9300d7d891bc842da540cc4ddef050da9bcd4` | Launch 1139 |
| MilestoneBurn | `0x45098bc496b3fdc870f89b8785047fb0e19ee99a` | Launch 1139 |
| LaunchToken (unchanged) | `0x4f2bacee5f2e7ce3f48dfbd635d96e9a8fcbe478` | Original token launch 994 |
| LendingPool | `0xe51a10d7b6978d153ad5075818c22e6ddfe15160` | `PawnShop.lendingPool()` |
| Active LockDiscount | `0x2546b64664146b1efc4fe66284386961fa25d52d` | `PawnShop.discountModule()` |
| VaultFactory | `0xa7820e9e40630f5c3edffd5868f5e6e6f886681b` | `PawnShop.vaultFactory()` |

The standalone LockDiscount deployed in step 3, `0x071b4d8f098b2a3611996a41da3c2c96d53482d7`, is **not the active module**. It is preserved as `standaloneLockDiscount` in `web/deployment.json`, outside the site's active contract list. VaultFactory creates a standalone CollateralVault per loan; there is no deployed CollateralVault implementation address.

All seven runtime addresses have code. At block **26156401**, all **194** ABI function selectors were present in their runtimes; ABI bytes match the pinned source and canonical ABI hashes match the launch record where supplied. Child `pawnShop()` bindings, pool WETH, PAWN bindings and the burn's 3,600-second age limit were read and checked. FloorRelay's full runtime hash matches the reviewed local artifact. This is interface/binding verification, not an independent source audit or byte-for-byte runtime comparison of every immutable-bearing contract. The [mainnet evidence](docs/frontend/relaunch/mainnet-verification.json) records block hash, code sizes, hashes and state. The [repeatable verifier](web/scripts/verify-launch.mjs) makes only public RPC reads:

```sh
node web/scripts/verify-launch.mjs --block 26156401
```

`web/deployment.json`, `web/public/imd-deployment.json`, `keeper/config.json` and `dist/imd-deployment.json` carry the new addresses. The token pool key and original token launch provenance remain in `web/deployment.json`; trading fee discovery uses the token's original receipt, since its pool was not redeployed. The browser re-discovers the current child contracts and verifies their code and bindings before enabling transactions.

At the recorded verification block, new loans were paused, the floor was unset, the pool had zero assets, and the burn question was unset. The owner and immutable burn setter were `0x23e5d7a7b4ea19530ec39c67cd46aa8c10d15acf`. These are dated observations, not promised current values; the site reads live state.

## Floor approval and milestone burn

In owner Setup or the public **Refresh floor**, paste an explorer request UUID and fetch its attestation. Fetching is read-only and works without a wallet. The site validates the exact question, chain, panel, signed answer, signer/domain, signature, age and floor block window before offering transactions. It displays the answer and full request hash.

- If a floor hash matches neither the governed pin nor `approvedQuestionHash`, the connected owner sees **Approve this hash** (`approveQuestionHash`). Other visitors see **Waiting for owner approval** and the full hash.
- Once the approval confirms, **Post floor** appears. Anyone with a connected Ethereum wallet may post. A matching governed/approved hash skips approval. Each transaction has a separate simulation, review and confirmation. An already stored or older floor sends no duplicate transaction.
- Approval is immediate and vouches for that request's question. It neither rotates the governed pin nor imposes its 48-hour cooldown. Starting or restarting an auction requires a fresh floor.

The burn question is exactly:

> What is the fully diluted market cap of the PAWN token (0x4f2bacee5f2e7ce3f48dfbd635d96e9a8fcbe478, Ethereum mainnet), computed as total supply times its 24-hour time-weighted average price from its Uniswap v4 ETH pool, converted to USD at the current ETH price? Answer as a uint256 in USD with 18 decimals.

After **Verify market cap**, answers below $1M show their value and that the milestone has not been reached, with no pin/burn action. At or above $1M, the immutable setter sees **Pin this answer**: `setQuestionHashOnce` when unset, otherwise `replaceQuestionHash`. After confirmation, **Burn** appears. A pinned matching answer skips re-pinning. The public Oracle & burn tab also supports a setter who is no longer PawnShop's owner.

A visible countdown uses the earlier of signed expiry and one hour after issue. Pinning and burning become unavailable at the deadline, including in an open transaction review; fresh evidence is required. The contract permits exactly 3,600 seconds, while the UI conservatively closes at zero remaining seconds. Burn is permissionless once pinned, requires a funded vault and is irreversible and one-time. Wallet confirmation and mining still take time, so do not wait until the deadline. The Risks section explains immediate owner admission, fresh-floor auctions and the burn's one-hour limit.

## Website: install, preview, rebuild and publish

Use Node.js 22.12+ with the existing committed `web/package-lock.json`. Dependencies and build configuration are unchanged. React, TypeScript, Vite and viem remain the existing stack.

```sh
npm ci --prefix web --cache /tmp/pawn-npm-cache
npm --prefix web run typecheck
npm --prefix web test
npm --prefix web run build
npm --prefix web run validate:export
npm --prefix web run preview
```

The production build uses local dependencies, pinned ABIs and Git objects without fetching network resources. `prepare.mjs` copies all eight `docs/abi/` interfaces after pinned-source/hash checks. `dist/` is the complete production export; Vite uses `base: './'` and hash routing for static gateway subpaths. The build regenerates the SHA-256 asset inventory. `npm --prefix web run dev` serves source. The existing pixel theme, local font and frog assets are retained. Do not include `node_modules`, caches, temporary browser installations or registry archives in a submission.

Run the current interaction and live-read checks (a bounded foreground server/browser process that closes on completion):

```sh
PLAYWRIGHT_BROWSERS_PATH=/tmp/pawn-playwright web/node_modules/.bin/playwright install chromium
PLAYWRIGHT_BROWSERS_PATH=/tmp/pawn-playwright web/node_modules/.bin/tsx web/tests/launch-browser.ts
PLAYWRIGHT_BROWSERS_PATH=/tmp/pawn-playwright node web/tests/launch-live.mjs
```

Actual results: production build, TypeScript check, export integrity, 21 unit tests and 8 production-browser scenarios passed. Desktop/mobile review covered 320, 390, 800 and 1440 CSS pixels, keyboard review/cancel, reduced motion, zero automated accessibility findings in Setup, and measured contrast pairs. The local production export also read real mainnet RPC data and displayed the new PawnShop in Setup; its read-only owner-address adapter rejected all signing methods. No on-chain transaction was signed or broadcast. [Validation](docs/frontend/relaunch/validation.md) distinguishes these checks from publication, documents limitations and records the six Better Interface domains. [DESIGN.md](DESIGN.md) describes the implemented design.

To publish under the same name, on an already authorized IdentityMD host:

```sh
imd site publish dist --name pawn
```

**Publication remains blocked.** In this run that command exited 1 with `not configured — run: imd pair --server <url>`. No CID or name update was returned. Both public ENS gateways (`pawn.site.identitymd.eth.limo` and `.eth.link`) failed TLS connection attempts, and the supplied browser connector returned `Transport closed`; local Chromium was used for rendered validation. Therefore the hosted Setup page could not be confirmed. No credentials were read, generated or requested. The hosting operator must publish this export through its authorized service, then verify that `#setup` lists `0xf0d9300d7d891bc842da540cc4ddef050da9bcd4` and compare hosted files to the exported SHA-256 inventory. See [publication evidence](docs/frontend/relaunch/publication.json). Earlier publication reports are historical.

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
| `FloorRelay` | none | Launch 1139 deployment; its address is PawnShop's `attester_` and MilestoneBurn's `signer_` |
| `LaunchToken` | none | Launch token; manifest token identifier `LaunchToken` |
| `PawnShop` | `address owner_, address token_, address weth_, address attester_` | Application; `$owner`, `$token`, Ethereum WETH below, the deployed FloorRelay |
| `VaultFactory` | none | Created inside `PawnShop`'s constructor; discover with `vaultFactory()`; only the shop can create vaults |
| `LendingPool` | `address owner_, address weth_, address shop_` | Created and configured inside `PawnShop`'s constructor; discover with `lendingPool()` |
| `LockDiscount` | `address token_, address shop_` | Created and configured inside `PawnShop`'s constructor; discover with `discountModule()` |
| `CollateralVault` | `address shop_` | One standalone instance per `pawn()`, created through VaultFactory and initialized atomically by PawnShop |
| `MilestoneBurn` | `address token_, address setter_, address signer_, address shop_` | Application after PawnShop; `$token`, `$owner`, supplied oracle signer below, `$contract:PawnShop` |

Launch 1139 deployed FloorRelay, PawnShop, the standalone spare LockDiscount and MilestoneBurn in that order, using the existing PAWN token. Pool and discount are constructor-created children with their shop permanently set; listing them again would deploy unrelated duplicates. A vault is created only when there is collateral. All constructors are nonpayable and use supported static argument types. No constructor takes or redistributes any of the launch token supply. Children and per-loan vaults also have exported ABIs and need source verification and indexing after deployment. Constructor arguments are explicit; control never defaults to the launch factory's `msg.sender`.

| Ethereum mainnet parameter | Value / authority |
| --- | --- |
| Chain | 1 |
| Intended owner and burn question setter | `0x23e5d7a7b4ea19530ec39c67cd46aa8c10d15acf`, from the workflow; manifest `$owner` must resolve to this address |
| Identity collection | `0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D`, from the workflow |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`, from the workflow |
| Initial attester for both consumers | FloorRelay `0x1ff0fb56f9a6c5c5c8201906d487ec4d8f5afc50`; its immutable IMD signing authority is `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| Floor and burn question hashes | Floor constructor preset `0x71ed43868c5c61fe21b72bbbdcc09913d4952a113a393c526e49f3289edf4be1`; burn initially unset, pinned to a verified qualifying answer by its setter |

The identity collection is initially enabled with 40% floor LTV for both terms and a 100% collection share limit. New loans are **paused** initially. Mainnet addresses are supplied inputs, not invented test deployment addresses. Deployment services must check the intended network and verify live code; local tests do not claim to have fork-tested mainnet.

**Launch token:** Pawn / PAWN, 18 decimals, exactly 1,000,000,000 tokens minted to its deployer. No mint, owner, pause, tax, blocklist or upgrade functions. The factory allocates supply and creates the launch trading pool. Application contracts neither seed that pool nor implement swap fees. The owner can claim its protocol trading income and voluntarily forward ETH to `LendingPool.donate()`. The network's trading fee comes from LaunchFees (1.25% in the supplied policy); a manifest fee of 3000 is not a claim that the trading pool charges 0.3%.

## Borrowing and repayment

1. Approve PawnShop for the seat. Optionally approve and lock PAWN in LockDiscount first.
2. Call `pawn(collection, tokenId, termId, minPrincipal, maxFee)`; it reverts `Slippage` if the principal is below `minPrincipal` or the fee above `maxFee` (the site sends the displayed principal −1% and fee +1%). New loans for a collection are closed for 48 hours after a governed question-hash write (constructor preset and immediate request-hash admission exempt). Term 0 starts at 30 days / 300 bps; term 1 at 7 days / 100 bps. Principal is always the configured term's maximum floor percentage, rounded down. There is no smaller-amount argument or automatic reduction to available liquidity; an oversized loan reverts. Minimum principal is 0.01 ETH. The collection's outstanding principal plus this loan must fit its share of `pool.totalAssets()`, and enough idle WETH must exist.
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

After **40 days from the auction's first start** (30 days holding at 50%; restarts do not move this clock, `auctionOpenedAt`), anyone may `writeOffAuction(loanId)`. Missing collateral permits this immediately after auction start. Collection debt and the PAWN commitment clear. While the seat is still held the pool keeps the loan on its book as an expected-loss allowance of principal less the current auction price (refreshable with `markAuctionLoss`, released through the seven-day stream on a fresh restart); the seat remains for sale at the original auction curve and a sale settles the principal as usual. Only once the collateral is gone does a second `writeOffAuction` call realise the unpaid principal (`debtRealised`), using reserves first; a seat that later returns to its vault is sold as a seven-day recovery stream, tracked by `cumulativeRecoveries`. Surplus above principal still belongs to the borrower; write-off grants no free collateral or owner rescue. Further write-offs revert. Even a collection that currently rejects transfers cannot block this financial write-off. A malicious discount module can still block its own release call.

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

Both consumers use the supplied **OracleAttestation v2** library unchanged. EIP-712 domain: `IdentityMD Oracle`, version `2`, current chain ID, verifying contract **the particular consumer**. The application requires `a.chainId == 1`, a pinned question hash, uint256 answer in wei (floor) or USD with 18 decimals (FDV), panel size at least five, quorum at least four, agreement at least quorum and no greater than panel size. It rejects future timestamps, expired signatures and reused request IDs. Floors have a 26-hour age limit; burn answers have a one-hour age limit. Floor updates must be strictly newer than the collection's stored timestamp and expire after they were issued; any signed lifetime is accepted (the service issues 24-hour floors) and the floor is fresh for the shorter of 26 hours and the signed lifetime. Longer lifetimes do not veto later answers, and no answer is used past its signed expiry or the 26-hour age limit. Because the oracle's `questionHash` covers each request's block window, the owner admits each floor request's hash with `approveQuestionHash` before it is posted (see ADAPTATION.md). Lending stops after the 26-hour age bound; changing the configured question also invalidates freshness until a new matching answer is accepted.

These are permissionless signed submissions, not contracts that buy oracle requests or receive Intake callbacks. Operators pay the oracle outside the application and submit the returned attestation to `submitFloor(collection,a,signature)` or `burn(a,signature)`. Before relay activation, a signature for the shop cannot trigger a burn. After activation, the relay translates the same authentic zero-consumer attestation into either caller’s domain; each consumer still checks its own configured question and policy. The constructor requires the real nonzero signer supplied above; the canonical verifier rejects zero signers. PawnShop signer rotations take 48 hours. MilestoneBurn binds to PawnShop in its constructor and validates the initial token and signer match. Anyone can `syncSigner()` after a shop rotation; `burn()` always synchronizes before verification, so a retired signer cannot race that explicit sync. The burn vault acquires no owner or withdrawal function, but trusts the shop's governed signer choices.

MilestoneBurn accepts voluntary PAWN transfers. Once the signed FDV reaches **1,000,000 × 10^18 USD units**, anyone may burn its entire current balance by transferring it to the expressly requested `0x000000000000000000000000000000000000dEaD`. This is a one-time sink transfer, not ERC-20 supply reduction. Empty burns revert. PAWN sent after the burn stays trapped forever, so check `burned()` before sending. There is no withdrawal, rescue, owner or second burn. Its immutable question setter configures the first hash with `setQuestionHashOnce` and can replace it with `replaceQuestionHash` until the burn fires. Use the verified 24-hour TWAP question above, pin an answer at or above the milestone and burn within its one-hour age/signed-expiry deadline. The setter cannot withdraw or move vault funds.

## After launch

- FloorRelay is deployed and active in launch 1139; no initial attester switch or wait is needed. Future signer rotations remain governed by PawnShop's 48-hour delay; MilestoneBurn follows that signer automatically.
- Owner: the governed identity.md question is preset. For each new explorer request, verify the floor question and use **Approve this hash**, then **Post floor**. Governed question rotations still use `queueCollection` / `executeCollection` with a 48-hour delay and borrowing cooldown; immediate request approval does not change that pin.
- Immutable burn setter: verify the exact PAWN TWAP FDV question, inspect an answer at or above $1M, then pin/re-pin and burn before the earlier of signed expiry or one hour after issue.
- Oracle operator: buy the displayed question on explorer.imd.fun with no consumer while FloorRelay is active. Paste the request UUID in the site, or configure request IDs in the keeper after the necessary owner/setter admission. Oracle purchases can be refused or inconclusive; they are not refunded by Pawn. The keeper's address configuration is updated; its existing runtime is unchanged by this frontend assignment.
- Anyone: fund lender liquidity with `deposit` / `depositETH` and optionally keeper reserves through `fundBounties`. Owner: submit a valid floor, check all setup and then call `setNewLoansPaused(false)`.
- Keepers/lenders: monitor auction prices and collateral availability, call `PawnShop.markAuctionLoss(loanId)` to keep loss allowances current, and call `writeOffAuction(loanId)` after 40 days unsold (or earlier if collateral is missing). These maintenance calls pay no extra bounty. Later auction sales remain possible.
- Owner: claim protocol trading income through the launch's deployed pool flow and forward desired ETH through `LendingPool.donate()` while `totalSupply() > 0`; otherwise retain it in the claiming wallet until lenders arrive. This is a voluntary operational responsibility, not an automatic token tax.
- Frontend/deployment services: discover constructor-created children, index events and per-loan vaults, publish the actual deployment addresses and use the exact trading `poolKey` in the handoff. This repository contains no guessed application addresses.

## Governance and risks

PawnShop and LendingPool have independent OpenZeppelin Ownable2Step ownership, explicitly initialized to the intended owner. Transfer/accept ownership on both when rotating operations. Renunciation is disabled. LockDiscount and MilestoneBurn have no ongoing owner, and vault control is limited to the borrower and immutable PawnShop.

PawnShop's immediate powers are pausing/unpausing new loans, disabling new borrowing for a collection, setting an unset collection hash once, immediately admitting a floor request hash with `approveQuestionHash`, and cancelling a queued change. Changes to terms, collection limits/status/question, attester, fee recipient and discount module wait 48 hours. Anyone can execute the exact queued payload from its 48-hour deadline through the following seven days, inclusive. A newer queue supersedes the older payload for the same setting (each term id and collection has its own setting); disabling a collection cancels its pending collection change. Expired payloads must be queued anew and wait another 48 hours. Terms are restricted to 7–90 days and 50–1,000 bps; LTV cannot exceed 4,000 bps; non-seat collection share cannot exceed 2,500 bps. The pool owner can queue only increases to its deposit cap, also delayed 48 hours. Economic constants such as fee split, bounty amounts, grace period and auction slopes are immutable; there is no generic arbitrary-call governance function.

Lenders trust the oracle attester's correctness, the collection's ownership/transfer implementation, and governance's future collection and module selections. The immediate one-shot question selection and the delayed attester/collection powers can economically expose **all idle lender ETH**: an unsuitable question with a genuine large answer, a malicious signer (including ERC-1271), or worthless owner-listed collateral can support a loan sized to the available liquidity. Values above the collection share ceiling revert rather than being clamped, but a tailored valuation can still borrow the entire idle balance. Absence of an explicit owner withdrawal is not protection from those valuation powers. Monitor 48-hour queues and immediate request-hash admissions; `approveQuestionHash` has no delay. Signer governance also controls which signatures the burn vault accepts. A malicious replacement module can impair new loans using it; it cannot change existing loans' stored module. The reserve can be exhausted; unsold collateral, a bad or stale auction floor, collection transfer restrictions or a failing oracle can prevent timely recovery. Worker enrollment and reward-service compatibility are external dependencies. Transactions can be reordered and auction purchases can compete. ETH credits remain claimable if a chosen receiver rejects ETH; retry with a different receiver. Forced ETH transfers are not counted as lender assets or administrator income and have no rescue path.

The contract/source conflicts documented for independent review are part of this handoff; passing tests do not resolve them or constitute launch approval.


The owner Setup page, night theme and keeper update are documented in [the operating handoff](docs/SETUP-AND-KEEPER.md). The installable hourly workflow and cron live in [keeper/](keeper/README.md). The static export continues to target `pawn.site.identitymd.eth`.
