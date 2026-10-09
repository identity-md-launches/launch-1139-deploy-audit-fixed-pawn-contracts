import { useEffect, useState } from "react";
import { useEngine } from "./engine";
import { Borrow, Lend, Lock } from "./finance";
import { Loans } from "./loans";
import { Trade } from "./trade";
import { Governance, Operations } from "./operations";
import { AddressLink, Notice, Stat, units } from "./components";
import { Setup } from "./setup";
import { Mascot } from "./mascot";
const tabs = [
  ["borrow", "Borrow"],
  ["lend", "Lend"],
  ["loans", "Loans & auctions"],
  ["lock", "Lock PAWN"],
  ["trade", "Trade"],
  ["oracle", "Oracle & burn"],
  ["governance", "Governance"],
] as const;
export default function App() {
  const e = useEngine(),
    s = e.snapshot,
    r = e.runtime;
  const [tab, setTab] = useState(location.hash.slice(1) || "borrow");
  useEffect(() => {
    const change = () => setTab(location.hash.slice(1) || "borrow");
    window.addEventListener("hashchange", change);
    return () => window.removeEventListener("hashchange", change);
  }, []);
  const wrong = !!e.account && e.chainId !== r?.deployment.chainId;
  const owner =
    !!e.account && e.account.toLowerCase() === s?.shop.owner.toLowerCase();
  const utilization =
    s && s.pool.totalAssets > 0n
      ? Number((s.pool.totalBorrowed * 10000n) / s.pool.totalAssets) / 100
      : 0;
  return (
    <>
      <a className="skip" href="#content">
        Skip to content
      </a>
      <header className="site-header">
        <a className="brand" href="#borrow">
          <Mascot className="brand-frog" />
          pawn<span className="brand-note">Open late. Fair terms.</span>
        </a>
        <div className="wallet">
          <span className="network-label">
            {r?.deployment.network.name ?? "Loading network"}
          </span>
          {e.account ? (
            <>
              <AddressLink value={e.account} />
              <button onClick={e.disconnect} disabled={e.pending}>
                Disconnect
              </button>
            </>
          ) : (
            <button
              className="connect"
              onClick={e.connect}
              disabled={e.walletBusy}
            >
              {e.walletBusy ? "Connecting…" : "Connect wallet"}
            </button>
          )}
        </div>
      </header>
      <main id="content">
        <section className="hero">
          <div className="hero-copy">
            <div className="eyebrow">
              <span className="tiny-pawn" aria-hidden="true">
                ♟
              </span>{" "}
              The identity.md seat pawn shop
            </div>
            <h1>
              Put your seat
              <br />
              to <em>work.</em>
            </h1>
            <p>
              Borrow ETH against your seat.
              <br />
              Keep it working in the swarm.
            </p>
            <div className="hero-tags">
              <span>Fixed terms</span>
              <span>Upfront fees</span>
              <span>No price liquidations</span>
            </div>
          </div>
          <div className="hero-art" aria-hidden="true">
            <div className="art-orbit orbit-one" />
            <div className="art-orbit orbit-two" />
            <div className="art-caption">YOUR SEAT HAS MORE TO GIVE.</div>
            <Mascot className="chess frog-hero" />
            <div className="art-note">
              <span>01 / PAWN</span>
              <strong>
                Keep your seat.
                <br />
                Unlock its value.
              </strong>
            </div>
          </div>
        </section>
        <section className="stats" aria-label="Live protocol statistics">
          <Stat
            label="Seat floor"
            value={`${units(s?.floor[0])} ETH`}
            note={
              s
                ? s.fresh
                  ? `Fresh · ${Math.max(0, Math.floor((Date.now() / 1000 - Number(s.floor[1])) / 3600))}h old`
                  : "Fresh floor needed"
                : "Awaiting contract read"
            }
          />
          <Stat
            label="Lending pool"
            value={`${units(s?.pool.totalAssets)} ETH`}
            note={
              s
                ? `${units(s.pool.depositCap)} ETH deposit cap`
                : "Live pool assets"
            }
          />
          <Stat
            label="Utilization"
            value={s ? `${utilization.toFixed(1)}%` : "—"}
            note="Outstanding loans / pool assets"
          />
          <Stat
            label="Lender fee income"
            value={`${units(s?.pool.cumulativeLoanFees)} ETH`}
            note="Cumulative · not an APR"
          />
        </section>
        <div className="health-bar">
          <span
            className={`health-dot ${s ? "healthy" : ""}`}
            aria-hidden="true"
          />
          <span>
            {e.loading
              ? "Refreshing chain state…"
              : s
                ? `Contract reads verified · block ${s.block.toLocaleString()}`
                : "Contract state unavailable"}
          </span>
          <button onClick={() => void e.refresh()} disabled={e.loading || !r}>
            Refresh state
          </button>
        </div>
        {e.transaction && (
          <div role="status">
            <Notice>
              <strong>
                {e.transaction.label}: {e.transaction.phase}.
              </strong>{" "}
              {e.transaction.hash && (
                <a
                  target="_blank"
                  rel="noreferrer"
                  href={`${r?.deployment.network.explorer}/tx/${e.transaction.hash}`}
                >
                  View transaction ↗
                </a>
              )}
              {e.transaction.error && <p>{e.transaction.error}</p>}
            </Notice>
          </div>
        )}
        {e.walletError && (
          <div role="alert">
            <Notice tone="warning">{e.walletError}</Notice>
          </div>
        )}
        {wrong && (
          <Notice tone="warning">
            <div className="switch-row">
              <span>
                Your wallet is on a different network. Switch before signing.
              </span>
              <button onClick={e.switchNetwork} disabled={e.walletBusy}>
                {e.walletBusy
                  ? "Switching…"
                  : `Switch to ${r?.deployment.network.name ?? "configured network"}`}
              </button>
            </div>
          </Notice>
        )}
        {e.error && (
          <div role="alert">
            <Notice tone="warning">
              <strong>Live state could not be verified.</strong> Transaction
              controls are disabled. Check your connection and use “Refresh
              state”.
              <details>
                <summary>Connection details</summary>
                <p className="break">{e.error}</p>
              </details>
            </Notice>
          </div>
        )}
        {!e.account && (
          <div className="connection-hint">
            Explore the protocol. Connect a wallet to see your balances and use
            transaction controls.
          </div>
        )}
        <nav className="tabs" aria-label="Protocol tools">
          {owner && (
            <a
              href="#setup"
              className={tab === "setup" ? "selected" : ""}
              aria-current={tab === "setup" ? "page" : undefined}
            >
              Setup
            </a>
          )}
          {tabs.map(([id, label]) => (
            <a
              key={id}
              className={tab === id ? "selected" : ""}
              aria-current={tab === id ? "page" : undefined}
              href={`#${id}`}
            >
              {label}
            </a>
          ))}
        </nav>
        <div className="tool" key={`${tab}-${e.account}-${e.chainId}`}>
          {tab === "setup" ? (
            owner ? (
              <Setup />
            ) : (
              <Governance />
            )
          ) : tab === "lend" ? (
            <Lend />
          ) : tab === "loans" ? (
            <Loans />
          ) : tab === "lock" ? (
            <Lock />
          ) : tab === "trade" ? (
            <Trade />
          ) : tab === "oracle" ? (
            <Operations />
          ) : tab === "governance" ? (
            <Governance />
          ) : (
            <Borrow />
          )}
        </div>
        <section className="risk-section">
          <div>
            <p className="eyebrow">Read before you sign</p>
            <h2>
              Clear terms.
              <br />
              Real responsibilities.
            </h2>
          </div>
          <div>
            <details>
              <summary>Borrowing & collateral risks</summary>
              <p>
                Missing the due date plus grace period can lead to an
                irreversible auction. A seat remains subject to its collection’s
                rules, including revocation or burning. Worker authorization and
                reward calls must satisfy the vault restrictions. Oracle values
                can be stale or incorrect. Starting or restarting an auction
                requires a fresh floor answer.
              </p>
            </details>
            <details>
              <summary>Lending & liquidity risks</summary>
              <p>
                Withdrawals are limited by idle assets. The reserve absorbs
                shortfalls first, but auction losses beyond it reduce lender
                value. Income vests over time. Share value and PAWN price can
                fall, and smart contract failures can cause loss.
              </p>
            </details>
            <details>
              <summary>Owner powers & oracle trust</summary>
              <p>
                The owner can pause new loans and queue term, collection,
                signer, fee-recipient and module changes. Lender-affecting
                changes wait 48 hours; the deposit cap can only rise. The owner
                admits each new floor request’s hash immediately, without a
                timelock, and vouches that it asks the governed question. The
                owner cannot directly withdraw collateral, pool ETH, reserves,
                locked PAWN or burn-vault tokens. The signed oracle and
                collection remain trust dependencies.
              </p>
            </details>
            <details>
              <summary>Fees, bounties & burn</summary>
              <p>
                Loan fees are split 85% to lenders and 15% to the protocol.
                Protocol fees fill the 0.2 ETH bounty target, then a reserve
                target of 5% of pool assets, then credit the fee recipient.
                Bounties are paid only when funded. Burn-vault deposits cannot
                be withdrawn and its burn can happen only once. Burning requires
                an unexpired market-cap answer under 1 hour old, based on PAWN’s
                24-hour time-weighted average price. The setter must pin the
                qualifying answer before anyone can burn.
              </p>
            </details>
          </div>
        </section>
        <section className="deployment">
          <h2>Know your contracts</h2>
          <p>
            Addresses and interfaces come from the deployment manifest used by
            this page.
          </p>
          <div className="contract-links">
            {r?.deployment.contracts
              .filter((c) => !["LendingPool", "LockDiscount"].includes(c.name))
              .map((c) => (
                <AddressLink key={c.name} value={c.address} label={c.name} />
              ))}
            {s && (
              <>
                <AddressLink
                  value={s.poolContract.address}
                  label="LendingPool"
                />
                <AddressLink
                  value={s.lockContract.address}
                  label="LockDiscount"
                />
              </>
            )}
          </div>
          <details>
            <summary>Deployment provenance</summary>
            <dl>
              <dt>Launch</dt>
              <dd>{r?.deployment.launchId ?? "Loading…"}</dd>
              <dt>Deployed source commit</dt>
              <dd>{r?.deployment.sourceCommit ?? "Loading…"}</dd>
              <dt>Attestation hash</dt>
              <dd>{r?.deployment.attestationHash ?? "Loading…"}</dd>
            </dl>
            <a href="./imd-deployment.json" target="_blank" rel="noreferrer">
              Open deployment manifest ↗
            </a>
          </details>
        </section>
      </main>
      <footer>
        <a className="brand" href="#borrow">
          pawn<span>♟</span>
        </a>
        <p>
          A pawn shop for working seats.
          <br />
          <small>Working seats. Golden opportunities.</small>
        </p>
        <a href="https://x.com/PawnIMD" target="_blank" rel="noreferrer">
          Follow @PawnIMD ↗
        </a>
      </footer>
    </>
  );
}
