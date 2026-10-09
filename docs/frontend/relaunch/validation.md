# Pawn launch 1139 frontend validation

Status: **Incomplete — publication is blocked by the unconfigured local IdentityMD publisher.** The requested local implementation, production export and checks are complete. This is the worker's evidence record, not independent certification. No mainnet transaction was signed or broadcast.

## Scope and assumptions

Updated the existing Pawn site for chain 1 and the latest pinned `evm_contracts` launch. Preserved the existing night/pixel theme, frog, token, pool key, contract source, dependencies and build configuration. Changed only deployment-dependent frontend behavior, requested oracle flows and risks copy, keeper addresses, associated checks and documentation. LendingPool, active LockDiscount and VaultFactory were discovered through the new PawnShop, not inferred from deployment order. The standalone step-3 LockDiscount is kept as historical provenance outside the active runtime contract list.

The full static production export is in `dist/` with relative assets and hash routing. The name remains `pawn.site.identitymd.eth`. The local source is React/TypeScript/Vite/viem; no replacement stack or new dependencies were introduced. The supplied browser connector was attempted and returned `Transport closed`. The existing Playwright dependency was used with Chromium 141.0.7390.37 installed under `/tmp/pawn-playwright`. Each validation script owns a temporary local server at `/preview/` and closes both browser and server in its foreground process.

## Actual verification

| Command/check | Result and evidence |
| --- | --- |
| `npm ci --prefix web --cache /tmp/pawn-npm-cache --ignore-scripts` | Exit 0; installed the unchanged lockfile. npm reported 3 dependency advisories (1 moderate, 2 high). Dependencies were not modified under this task's restrictions. |
| `node web/scripts/verify-launch.mjs --block 26156401` | Exit 0. Mainnet chain, block hash, runtime presence, 194 ABI selectors, pinned ABI bytes/hashes, child/token/WETH bindings and burn age read successfully. FloorRelay runtime hash matches the reviewed artifact. `mainnet-verification.json` and `verification-command.txt`. |
| `npm --prefix web run typecheck` | Exit 0; `typecheck.txt`. |
| `npm --prefix web test` | Exit 0; 21 passing tests, 0 failed. `unit-tests.txt`. Includes real relay packing/signature fixture, exact TWAP wording, fresh/stale/future/early-expiry/boundary attestations, tampering, below-threshold precision, ABI and original-token fee provenance checks. |
| `npm --prefix web run build` | Exit 0 after final source changes; `build.txt`. Eight ABIs verified/copied. Vite emitted a non-fatal >500 kB JS chunk warning. No network resources are fetched by the production build. |
| `npm --prefix web run validate:export` | Exit 0; 16 indexed runtime assets, exact manifest/network/pool/ABI hashes and every SHA-256 match; `export-check.txt`. |
| `PLAYWRIGHT_BROWSERS_PATH=/tmp/pawn-playwright web/node_modules/.bin/tsx web/tests/launch-browser.ts` | Exit 0; 8 production-browser scenarios, no page exceptions or failed resource requests, 0 axe findings in Setup. `browser-results.json`, `browser-command.txt`. All transaction attempts use deterministic RPC/wallet fixtures and a public test signer. |
| `PLAYWRIGHT_BROWSERS_PATH=/tmp/pawn-playwright node web/tests/launch-live.mjs` | Exit 0; production export using real public mainnet RPCs, with no RPC interception. Setup lists the new PawnShop and three children; FloorRelay active. Original token receipt, factory position and `claimFees` read simulation passed. `live-browser.json`, `live-browser-command.txt`. A read-only public-owner-address adapter opens Setup and throws on signing/mutation methods. This is local rendering with live chain state, not a hosted-site check. |
| Address/question consistency | All seven names/addresses agree across frontend handoff, public manifest, export and keeper config. Spare module absent from runtime export. README's quoted TWAP question matches `CAP_QUESTION` exactly. |
| `git diff --check` and path checks | Passed. No contract, dependency, lockfile, Foundry/Vite/TS configuration, ignore file, `.github` or `.env` changes. Git metadata was not modified. No submodule added. Packaging sizes recorded in `delivery-check.json`. |
| `imd site publish dist --name pawn` | Exit 1: `not configured — run: imd pair --server <url>`. No content URI/name update. Both ENS gateway reads failed TLS with curl exit 35; the web tool also could not access either homepage. `publication.json`. |

The browser interaction scenarios verify:

1. New Setup contract list; verification sends no transaction; owner approval calls `approveQuestionHash(collection, hash)` before a separate reviewed `submitFloor`. A stored/newer floor prevents another submission.
2. Disconnected public floor reads display **Waiting for owner approval** and the full hash without showing owner controls.
3. An already approved floor skips approval; a changed approval before transaction review prevents submission.
4. Below-$1M answers retain their amount and show the unmet milestone with no pin/burn control; stale or tampered evidence is rejected.
5. Exactly $1M qualifies; unset burn hash calls `setQuestionHashOnce`, then a separately reviewed `burn` consumes the verified evidence.
6. An immutable setter who is not the PawnShop owner can use the public burn flow; an existing pin uses `replaceQuestionHash`.
7. Non-setters wait for the setter. Earlier signed expiry controls the countdown and disables an already open Burn confirmation. Time is accelerated in the browser test; no one-hour real wait occurs.
8. Setup reflows, keyboard review/cancel works, reduced motion removes transitions, and the requested risks are present.

The historical `setup-browser.ts` command delegates to this current launch suite. Other historical screenshot/report files remain unchanged and are not evidence for this run. Solidity tests were not rerun because no contract code changed. The historical broad `tests/browser.ts` suite was not run; the current targeted suite covers the affected primary interactions.

## Better Interface: six-domain review

Read the pinned workflow, all six domains' core principles and the design documentation method. Applied them while implementing, then reviewed the final production export. Root `DESIGN.md` describes actual tokens/components and responsive behavior. The established visual direction remains authoritative; this task did not redesign unrelated pages.

| Domain | Coverage | Evidence and limits |
| --- | --- | --- |
| Accessibility | Checked | Native labelled fields/buttons, persistent polite fetch status, alert errors, full visible hash, disabled expired actions, no live announcement per countdown tick. Keyboard moves to Pin, opens review, reaches confirmation, cancels without sending. Viewed gold focus ring in `keyboard-focus.png`. axe: 0 violations in Setup. No native screen-reader session, physical device or full accessibility conformance claim. |
| Layout | Checked | Setup and full long-hash state at 320, 390, 800 and 1440 CSS px; document width never exceeded viewport. Real-mainnet Setup checked at the same widths. Inspected desktop/mobile captures and focused flow. Native browser 200% zoom and RTL not tested; English-only product has no localization variant. |
| Writing | Checked | Fetch is labelled as read-only; approval, pin/re-pin, posting and irreversible burn have distinct consequences in review. Non-owner/setter and below-milestone states explain the next step. Expired answers request fresh evidence. Exact TWAP wording and all three risks verified. |
| Typography | Checked | Existing local VT323 display face and Arial/Helvetica body stack preserved, 16px mobile inputs, full question/hash wrap, tabular countdown inherited from Pair. Screenshots show complete readable flow with no document clipping at tested widths. No cross-platform font/OS comparison. |
| Colors | Checked | Measured opaque rendered pairs in Chromium: main text `#f2e8d0` / panel `#173b32` **10.09:1**; muted `#c9c6ac` / panel **7.12:1**; action text `#0d2619` / fill `#e0b14c` **8.07:1**; warning `#f6d27a` / `#403921` **7.90:1**. Full hash **10.09:1**. No claim for unmeasured gradient/art pairs or disabled controls. Single fixed night theme; theme switching not applicable. |
| UI | Checked | Reused Panel/Pair/Notice/Field/Action, review/simulation/confirmation and clear loading/empty/invalid/waiting/expired/completed states. Countdown does not flash; reduced-motion computed transition duration was 0s. Existing pixel shapes and shadows retained. No modal/custom animation was added; slow-motion animation-panel review not applicable to the new timer. |

## Findings and disposition

| Severity | Source location | Finding / effect | Fix and recheck |
| --- | --- | --- | --- |
| High | `web/deployment.json:1`, `web/src/engine.tsx:97`, `web/scripts/prepare.mjs:6` | Previous launch addresses and export ABIs targeted the old PawnShop; VaultFactory was not discovered. | Latest launch/provenance and derived child addresses; code/binding/ABI checks; Factory/Relay ABI export. Live-mainnet Setup and manifest consistency passed. |
| High | `web/src/oracle-flow.tsx:63` | Hash mismatch threw before the owner could admit a valid new request; the previous flow also auto-sent setup/post transactions after fetch. | Verify signed evidence independently of admission, display hash, explicit owner approval then Post floor; public waiting state. Browser checks 1–3 passed. |
| High | `web/src/oracle.ts:19`, `web/src/oracle-flow.tsx:304` | Spot-price cap question, no usable per-request re-pin path and no one-hour UI limit. | Exact 24-hour TWAP question, threshold gating, immutable setter pin/re-pin and deadline-limited Burn. Unit and browser checks 4–7 passed. |
| Medium | `web/src/trading-fees.ts:16` | Reading the replacement shop receipt would detach trading fee discovery from the unchanged token pool. | Preserve `tokenLaunch`; verify fees against LaunchToken's original receipt/children and exact pool key. Unit tests and live-mainnet factory/fee reads passed. |
| Medium | `web/src/App.tsx:275` | Risk disclosures omitted the new immediate admission/fresh-floor/one-hour requirements. | Added all three disclosures; rendered browser assertions passed. |
| Low | `web/src/oracle-flow.tsx:179` | Initial rendered countdown could briefly show `60m 01s` because the last local tick preceded the newly recorded observation time. | Clamp elapsed time to zero; final focused screenshot shows `60m 00s`; countdown and expiry interaction checks passed. |
| Low | `web/src/App.tsx:325`, `web/src/setup.tsx:52` | Adding discovered contracts to the manifest could duplicate pool/module links in the UI. | Render each relevant address once while keeping live child discovery. Final Setup and footer inspected. |

Initial harness runs also exposed an obsolete 26-hour minimum-lifetime test, case-sensitive checksum comparisons and a contrast selector for an absent notice. These test assumptions were corrected against the current pinned contract/UI; they were not production failures. New full-page screenshots are captured directly as JPEG to keep the delivery small; no runtime assets were dropped.

## Screenshots and remaining limitations

- `setup-desktop.jpg` and `setup-mobile.jpg`: final production export, deterministic transaction fixtures. The mock's trading-receipt error is outside these interaction scenarios; real mainnet fee provenance is separately verified in `live-browser.json`.
- `burn-flow-mobile.png`: complete qualified answer, wrapped hash, countdown and Pin action with deterministic signed evidence. Its test EOA warning is fixture-only; real deployed FloorRelay activation was verified separately.
- `keyboard-focus.png`: visible focus ring around Pin, after keyboard navigation.
- `live-mainnet-contracts.png`: actual mainnet-derived Setup contract list in local production rendering, including new PawnShop and active children.

No new oracle answer was purchased and no mainnet approval, posting, pin, burn or claim transaction was sent. Mining-time expiry, real wallet-extension UX, screen readers, native 200% zoom and physical devices remain untested. Simulations and fixture receipts are not proofs of live transaction completion. Selector presence and binding checks are not full runtime source verification for immutable-bearing contracts.

**Remaining required work:** an authorized hosting operator must run the documented publish command, then confirm the hosted `#setup` lists the new PawnShop and verify the served inventory. The worker cannot authenticate the unconfigured publisher within this repository and did not access credentials. No hosted publication or complete assignment success is claimed.

Design guidance attribution: Jakub Krehel's Better Interface (MIT, `267330e1adfc66a718fb65fa6918c1f06d0a689e`) and Paul Bakaus's Impeccable documentation guidance (Apache-2.0, `9d715cc4f5564a990ca8345abfdd5df6dc9b41c8`). Preserved licenses: `docs/frontend/owner-controls/design-guidance-LICENSE.txt`.
