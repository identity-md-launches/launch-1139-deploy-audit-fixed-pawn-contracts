# Pawn interface design

## Overview

Pawn serves seat borrowers, ETH lenders, PAWN holders and contract owners. The existing pixel pawn shop at night is preserved: deep green surfaces, cream body text, gold controls, and an original frog pawnbroker. The hero and four live statistics precede hash navigation and transaction panels. This update targets launch 1139 and adds explicit floor admission, burn answer pinning and the one-hour countdown. It retains the established visual system.

The source of truth is `web/src/style.css`, `components.tsx`, `App.tsx`, `setup.tsx`, `oracle-flow.tsx`, `operations.tsx` and `governance-state.tsx`. The later night-theme declarations in the stylesheet override the earlier light palette. This document supersedes the earlier light-theme description in `docs/DESIGN.md`.

## Colors

| Active token | Value | Role |
| --- | --- | --- |
| `--page` | `#0d2619` | Canvas and dark hero art |
| `--surface` | `#173b32` | Panels and statistics |
| `--surface-muted` | `#21483a` | Receipts, notices, inline reviews |
| `--text` | `#f2e8d0` | Main text |
| `--muted` | `#c9c6ac` | Secondary text and labels |
| `--border` | `#52634a` | Panel edges and separators |
| `--field-border` | `#89956e` | Input and review outlines |
| `--accent` | `#e0b14c` | Gold action fill |
| `--accent-hover` | `#f6d27a` | Hover fill |
| `--on-accent` | `#0d2619` | Text on gold |
| `--highlight`, `--focus` | `#f6d27a` | Highlight and focus |
| `--warning-bg`, `--warning-text` | `#403921`, `#f6d27a` | Warning notices |
| `--error`, `--success` | `#ffaca1`, `#bcdea0` | Textual transaction status |

The body has a fixed 145-degree gradient from `#173b32` to `#0d2619` at 65%. Art uses additional greens and golds. This is one fixed night theme; no theme switch is implemented. Rendered oracle flow text measured 10.09:1 and muted labels 7.12:1 against `#173b32`; action text on gold measured 8.07:1 and warning text on its opaque surface measured 7.90:1 in Chromium. These are specific opaque pairs, not a claim about every state or the body gradient.

## Typography

`PawnPixel` is local VT323 Regular (`web/public/fonts/VT323-Regular.ttf`, OFL license beside it), with monospace fallback and `font-display: swap`. Headings, branding, eyebrows and large statistics use it at weight 400 and `.03em` letter spacing. Normal text uses Arial, Helvetica, sans-serif, 16px root and 1.55 line-height. No font service is required.

The desktop h1 uses `clamp(3.6rem, 10vw, 6.5rem)` and 1.04 line-height; mobile `.hero-copy h1` overrides it to 3.6rem at 720px and 3.1rem at 400px. General h2/h3 sizes are 2.3rem/1.7rem; specific risk/deployment headings retain their existing smaller sizes. `--small` is .8125rem, `--body` 1rem and `--heading` 1.625rem. Inputs/selects use 1rem; textareas rise from .9rem to 1rem at 720px. Body emphasis uses the system font stack.

Paragraphs cap at 68ch and use pretty wrapping; headings balance. `Pair` and addresses use tabular numbers; queue countdowns inherit that treatment. Long operation hashes remain selectable and wrap completely. The local VT323 font is bundled in the production export. System-font substitution depends on the device; see current validation for rendered font loading checks.

## Layout

Header, main and footer cap at 1280px with 48px desktop inline padding. `.workspace-grid` uses `1.12fr 1fr`, 24px gap, and `min-width: 0` children. Panels have 32px padding and 24px bottom spacing; fields use 20px block spacing and 7px internal gaps. Receipts/notices use 16px/20px padding. Navigation and button rows wrap.

At 1000px, outer padding becomes 28px and panels 26px. At 720px, tool panels and risk sections stack, statistics become two columns, the hero artwork is hidden, and header/footer/form rows wrap; panels use 24px padding. At 600px the brand tagline hides and OracleFlow padding becomes 12px. At 400px, outer padding becomes 16px, panel padding 20px and label/value rows wrap. The header frog remains visible on mobile.

The final Setup with a qualifying burn answer was checked at 320, 390, 800 and 1440 CSS pixels without document overflow. Its full request hash wraps without truncation; native inputs scroll long UUIDs within their field. The same widths were checked with real mainnet Setup reads. Desktop/mobile and focused-action screenshots were inspected. Native zoom, physical devices and RTL were not tested.

## Elevation & depth

Hard pixel shadows use `#091c13`: buttons 3px/3px, panels 4px/4px and hero 8px/8px. The frog art has a 12px drop shadow. Panel borders define groups; receipt/review surfaces use a lighter green. Reviews are inline rather than modal. Focused skip navigation is the only overlay.

## Shapes

The active `--radius` is 2px; panels, hero and buttons use square pixel-like corners. Existing field rules retain 7px corners because `.field input` is more specific than the later element selector. Receipts/notices keep 8px corners, reviews 8px and small hero tags their pill shape. These established exceptions are unchanged.

## Components

- `Panel`, `Pair`, `Stat`, `Notice` in `web/src/components.tsx` provide section headings, label/value rows, metrics and info/warning surfaces. States always have text alongside color.
- `Field` binds native labels and hints to inputs, selects and textareas. `ContractForm` uses native details/summary to reveal ABI-derived inputs.
- `Action` handles review, simulation, explicit confirmation, wallet submission, receipt and error states. Native disabled states reflect transaction readiness. `ReadButton` provides loading and retry feedback for reads.
- `AddressLink` provides an explorer link and copy button; full checksummed addresses are available in the title. `units` and `when` format values.
- Hash navigation in `App.tsx` uses real links with `aria-current`. Setup appears only for a connected PawnShop owner. A non-owner direct `#setup` visit displays Governance state. Public Governance shows paused/open loans, cap, floor hash Set/Not set, signer and queues; each contract's controls require its own owner. The guided burn pin action is available to the immutable question setter, including on the public Oracle & burn tab if that setter is not the current PawnShop owner. Owner claim buttons remain inside owner views. Personal borrowing/lending claims and public floor refresh retain their existing behavior.
- `QueuedChanges` in `web/src/governance-state.tsx` enumerates ChangeQueued events from the verified deployment block in 2,000-block chunks, then checks current storage to filter completed/cancelled/superseded operations. Loading, empty and read-error messages are explicit. `Countdown` updates once per second, covers delay/ready/expired states, and uses no live region so ticking does not interrupt assistive technology. The generic component accepts an optional expiry; the burn flow maintains its own answer deadline as described below.
- `OracleFlow` in `web/src/oracle-flow.tsx` accepts `kind="floor" | "cap"` and `publicFlow`. It reuses `Field`, `Pair`, `Notice` and `Action` rather than introducing new visual tokens. A native fetch button performs read-only validation, a persistent polite status region reports progress, and errors use `role="alert"`. Cancelling polling or changing the request invalidates pending results. The full answer hash appears in a selectable wrapping `code` element.
- Floor states are empty/fetching, invalid, waiting for owner, owner approval, ready to post, and already posted. The requested **Approve this hash** and **Post floor** actions are sequential, with separate review and confirmation. Non-owners see the waiting reason and hash. Approval updates from refreshed chain state.
- Burn states are below milestone, waiting for setter, pin/re-pin, ready to burn, expired, empty vault and completed. **Pin this answer** has the same visible label for first pin and replacement; its review explains which operation will run. The `$1M` threshold uses integer 18-decimal arithmetic. **Burn** reviews the irreversible full vault amount.
- The burn `role="timer"` uses tabular numbers inherited from `Pair` and `aria-live="off"` so each tick does not announce. It counts down from the earlier of `issuedAt + 3600` or signed expiry using observed chain time and elapsed browser time, clamps at zero and disables actions/review confirmation when expired. Text explains how to fetch a fresh answer. It does not animate or flash.
- `Mascot` and `web/public/pawn.svg` contain the pixel frog, eyeshade, loupe, bow tie and three gold balls. The unchanged SVG is the relative favicon `./pawn.svg` in the export.

Focus uses a 3px gold outline with 4px offset, or 2px offset on inputs; forced colors uses `Highlight`. Buttons are at least 44px tall, copy buttons and summaries 32px. Color transitions are 120ms and press scale .96, only under `prefers-reduced-motion: no-preference`.

## Do's and don'ts

Reuse the existing tokens, panels, field labels, inline transaction review and hash routes. Keep unavailable reads explicit, display amounts in their actual units, and compare wallet addresses with live contract ownership. Hide owner controls by conditional rendering. Preserve public visibility of state and the public Refresh floor button.

Preserve the theme and frog; update deployment records only from verified launch evidence and live getters. Do not imply that UI visibility changes contract permissions. Keep real financial transactions out of browser validation. A new transaction page should start with `Panel` and `Field`, use `Action` for simulation/review/confirmation, show `Pair` values with explicit units, and use the existing `.workspace-grid` stacking behavior. Do not auto-send a transaction after fetching data.

Design review used the pinned Better Interface guidance by Jakub Krehel (MIT, commit `267330e1adfc66a718fb65fa6918c1f06d0a689e`) and documentation guidance adapted from Paul Bakaus's Impeccable (Apache-2.0, commit `9d715cc4f5564a990ca8345abfdd5df6dc9b41c8`). License notices are retained in `docs/frontend/owner-controls/design-guidance-LICENSE.txt`.

Current six-domain review, screenshots, measured contrasts and limitations: [relaunch validation](docs/frontend/relaunch/validation.md). Mock transaction screenshots identify their test fixture context; [live mainnet Setup evidence](docs/frontend/relaunch/live-browser.json) uses a read-only owner-address adapter. Hosted publication remains unconfirmed.
