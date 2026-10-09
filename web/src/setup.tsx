import { useEffect, useState } from "react";
import { useEngine } from "./engine";
import {
  Action,
  AddressLink,
  Field,
  Notice,
  Pair,
  Panel,
  units,
  when,
} from "./components";
import { amount } from "./logic";
import { OracleFlow } from "./oracle-flow";
import { tradingFees } from "./trading-fees";
import { zeroHash } from "./oracle";
import { Countdown } from "./governance-state";
export function Setup() {
  const e = useEngine(),
    r = e.runtime,
    s = e.snapshot;
  const [cap, setCap] = useState(""),
    [seed, setSeed] = useState(""),
    [fees, setFees] = useState<Awaited<ReturnType<typeof tradingFees>>>(),
    [feeError, setFeeError] = useState("");
  useEffect(() => {
    let live = true;
    setFees(undefined);
    if (r && e.account)
      tradingFees(r, e.account)
        .then((f) => {
          if (live) {
            setFees(f);
            setFeeError("");
          }
        })
        .catch((x) => {
          if (live) setFeeError(x.message);
        });
    return () => {
      live = false;
    };
  }, [s?.at, e.account]);
  if (!s || !r || e.account?.toLowerCase() !== s.shop.owner.toLowerCase())
    return (
      <Notice>Connect the current PawnShop owner wallet to view Setup.</Notice>
    );
  const done = (value: boolean) => (
    <span className="step-state">{value ? "Done" : "Pending"}</span>
  );
  const contracts = [
    ...r.deployment.contracts.filter(
      (c) => !["LendingPool", "LockDiscount", "VaultFactory"].includes(c.name),
    ),
    s.poolContract,
    s.lockContract,
    { name: "VaultFactory", address: s.shop.vaultFactory },
    { name: "PoolInitializationGuard", address: r.deployment.poolKey.hooks },
    ...(fees
      ? [fees.factory, { name: "MerkleDistributor", address: fees.distributor }]
      : []),
  ];
  return (
    <>
      <Panel title="Your shop. Ready for business." kicker="Owner / Setup">
        <div className="setup-contracts">
          {contracts.map((c) => (
            <div key={c.name}>
              <AddressLink value={c.address} label={c.name} />
              <code>{c.address}</code>
            </div>
          ))}
        </div>
      </Panel>
      <Panel title="Constructor presets">
        <Pair label="identity.md floor question hash">
          {done(s.collection[5] === s.shop.IDENTITY_QUESTION_HASH)}{" "}
          <code>{s.shop.IDENTITY_QUESTION_HASH}</code>
        </Pair>
        <Pair label="Attester (FloorRelay)">
          {done(true)} <AddressLink value={s.shop.oracleSigner} />
        </Pair>
        <p className="muted">
          Both are set at deployment; no setup transaction or attester switch is
          needed. Buy answers on explorer.imd.fun with no consumer and paste the
          request id below.
        </p>
      </Panel>
      <div className="workspace-grid">
        <Panel title="1. Floor">
          <Pair label="Question configured">
            {done(s.collection[5] !== zeroHash)}
          </Pair>
          <Pair label="Fresh floor posted">{done(s.fresh)}</Pair>
          <Pair label="Stored floor">{units(s.floor[0])} ETH</Pair>
          <OracleFlow />
        </Panel>
        <Panel title="2. Burn">
          <Pair label="Vault funded">
            {done(s.burn.balance >= 10000000n * 10n ** 18n || s.burn.burned)}
          </Pair>
          <Pair label="Vault balance">{units(s.burn.balance)} PAWN</Pair>
          <Pair label="Question configured">
            {done(s.burn.questionHash !== zeroHash)}
          </Pair>
          <Pair label="Milestone burn">{done(s.burn.burned)}</Pair>
          <Action
            label="Send 10,000,000 PAWN"
            disabled={
              s.burn.burned ||
              s.burn.balance >= 10000000n * 10n ** 18n ||
              s.token.balance < 10000000n * 10n ** 18n
            }
            prepare={() => ({
              contract: r.contracts.LaunchToken,
              functionName: "transfer",
              args: [r.contracts.MilestoneBurn.address, 10000000n * 10n ** 18n],
              summary:
                "Permanently send 10,000,000 PAWN to the one-time burn vault. No withdrawal is available.",
            })}
          />
          <OracleFlow kind="cap" />
        </Panel>
        <Panel title="3. Open">
          <Pair label="New loans open">{done(!s.shop.newLoansPaused)}</Pair>
          <Action
            label="Unpause"
            disabled={!s.shop.newLoansPaused || !s.fresh}
            prepare={() => ({
              contract: r.contracts.PawnShop,
              functionName: "setNewLoansPaused",
              args: [false],
              summary: "Open new loans with the verified floor.",
            })}
          />
          <Pair label="Deposit cap">{units(s.pool.depositCap)} ETH</Pair>
          {e.account?.toLowerCase() === s.pool.owner.toLowerCase() && (
            <>
              <Field label="Deposit cap (ETH)" value={cap} onChange={setCap} />
              <Action
                key={cap}
                label="Raise"
                disabled={
                  e.account?.toLowerCase() !== s.pool.owner.toLowerCase()
                }
                prepare={() => {
                  const n = amount(cap);
                  if (n <= s.pool.depositCap)
                    throw Error("The cap can only rise.");
                  return {
                    contract: s.poolContract,
                    functionName: "queueDepositCap",
                    args: [n],
                    summary: `Queue a cap of ${cap} ETH. Execute after the required 48-hour delay.`,
                  };
                }}
              />
              <Pair label="Queued cap">
                {units(s.pool.pendingCap)} ETH · {when(s.pool.pendingCapAt)}
                {!!s.pool.pendingCapAt && (
                  <>
                    {" "}
                    · <Countdown at={s.pool.pendingCapAt} />
                  </>
                )}
              </Pair>
              <Action
                label="Apply raised cap"
                disabled={
                  !s.pool.pendingCapAt ||
                  BigInt(Math.floor(Date.now() / 1000)) < s.pool.pendingCapAt
                }
                prepare={() => ({
                  contract: s.poolContract,
                  functionName: "executeDepositCap",
                  summary: "Apply the mature deposit cap increase.",
                })}
              />
            </>
          )}
          <Pair label="Pool seeded">{done(s.pool.totalAssets > 0n)}</Pair>
          <Field label="Deposit ETH" value={seed} onChange={setSeed} />
          <Action
            key={seed}
            label="Deposit ETH"
            prepare={() => {
              const n = amount(seed);
              if (n > s.pool.maxDeposit)
                throw Error("Amount exceeds remaining deposit cap.");
              return {
                contract: s.poolContract,
                functionName: "depositETH",
                args: [e.account],
                value: n,
                summary: `Seed the pool with ${seed} ETH; receive lender shares.`,
              };
            }}
          />
        </Panel>
        <Panel title="4. Claims">
          <Pair label="Trading fees pending">
            {fees
              ? `${units(fees.amounts[0])} ETH + ${units(fees.amounts[1])} PAWN`
              : "Pending verified factory read"}
          </Pair>
          {feeError && <p role="alert">{feeError}</p>}
          <Action
            label="Claim trading fees"
            disabled={
              !fees || (fees.amounts[0] === 0n && fees.amounts[1] === 0n)
            }
            prepare={async () => {
              const f = await tradingFees(r, e.account!);
              return {
                contract: f.factory,
                functionName: "claimFees",
                args: [f.launchNumber],
                summary:
                  "Distribute accrued trading fees to the factory position’s fixed recipients. This does not change its liquidity or recipient.",
              };
            }}
          />
          {fees && (
            <Pair label="Factory fee recipient">
              <AddressLink value={fees.recipient} />
            </Pair>
          )}
          <Pair label="Shop credits pending">
            {units(s.shop.claimable)} ETH · {done(!s.shop.claimable)}
          </Pair>
          <Notice>
            Bounty credits and protocol fees share one on-chain shop balance,
            alongside borrower and auction credits. Either shop claim button
            pays the full pending balance; the other then shows zero.
          </Notice>
          {["Claim bounty credits", "Claim protocol fees"].map((label) => (
            <div key={label}>
              <Pair
                label={`${label === "Claim bounty credits" ? "Bounty credits" : "Protocol fees"} pending (shared)`}
              >
                {units(s.shop.claimable)} ETH
              </Pair>
              <Action
                label={label}
                disabled={!s.shop.claimable}
                prepare={() => ({
                  contract: r.contracts.PawnShop,
                  functionName: "claim",
                  args: [e.account],
                  summary: `Claim your full ${units(s.shop.claimable)} ETH shop balance, including all credited categories.`,
                })}
              />
            </div>
          ))}
          <Pair label="Claims settled">
            {done(
              !s.shop.claimable &&
                !!fees &&
                fees.amounts[0] === 0n &&
                fees.amounts[1] === 0n,
            )}
          </Pair>
        </Panel>
      </div>
    </>
  );
}
