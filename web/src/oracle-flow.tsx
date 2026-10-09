import { useEffect, useRef, useState } from "react";
import { useEngine, read } from "./engine";

import { Action, Field, Notice, Pair, units } from "./components";
import { loadEvidence, validateEvidence, signerMode, question, zeroHash, type Kind } from "./oracle";
import { RelayStatus } from "./relay-setup";
export function OracleFlow({
  kind = "floor",
  publicFlow = false,
}: {
  kind?: Kind;
  publicFlow?: boolean;
}) {
  const e = useEngine(),
    r = e.runtime,
    s = e.snapshot;
  const [id, setId] = useState(""),
    [busy, setBusy] = useState(false),
    [status, setStatus] = useState(""),
    [error, setError] = useState(""),
    [evidence, setEvidence] = useState<any>(),
    [cap, setCap] = useState<bigint>();
  const active = useRef(true),
    cancel = useRef(false);
  useEffect(() => {
    active.current = true;
    return () => {
      active.current = false;
      cancel.current = true;
    };
  }, []);
  const storageKey = `pawn-oracle-${e.account}-${kind}`;
  useEffect(() => {
    setId(localStorage.getItem(storageKey + "-id") ?? "");
    setEvidence(undefined);
    setCap(undefined);
  }, [storageKey]);
  async function walletCheck() {
    if (!e.ready || !r || !s || !e.account || !window.ethereum)
      throw Error("Connect a wallet on Ethereum and refresh chain state.");
    const accounts = await window.ethereum.request({ method: "eth_accounts" }),
      chain = await window.ethereum.request({ method: "eth_chainId" });
    if (
      accounts[0]?.toLowerCase() !== e.account.toLowerCase() ||
      Number(chain) !== 1 ||
      !active.current ||
      cancel.current
    )
      throw Error(
        "Wallet changed or flow cancelled. Resume with your request id.",
      );

  }
  function update(text: string) {
    if (active.current) setStatus(text);
  }
  async function checked(ev: any) {
    const consumer =
      kind === "floor" ? r!.contracts.PawnShop : r!.contracts.MilestoneBurn;
    const [block, signer, pinned] = await Promise.all([
      r!.client.getBlock(),
      read(r!, r!.contracts.PawnShop, "oracleSigner"),
      kind === "floor"
        ? Promise.all([
            read(r!, r!.contracts.PawnShop, "collections", [
              s!.collectionAddress,
            ]).then((x) => x[5]),
            // The owner may admit one request's hash on top of the governed pin (ADAPTATION.md).
            read(r!, r!.contracts.PawnShop, "approvedQuestionHash", [
              s!.collectionAddress,
            ]),
          ]).then(([governed, approved]) =>
            approved !== zeroHash &&
            String(ev.detail?.questionHash).toLowerCase() ===
              String(approved).toLowerCase()
              ? approved
              : governed,
          )
        : read(r!, consumer, "questionHash"),
    ]);
    return validateEvidence(
      ev,
      kind,
      consumer.address,
      signer,
      pinned,
      Number(block.timestamp),
      await signerMode(r!.client, signer),
    );
  }
  async function post(ev: any) {
    const valid = await checked(ev);
    if (!active.current || cancel.current) return;
    setEvidence(ev);
    if (kind === "cap") setCap(valid.value);
    const c =
      kind === "floor" ? r!.contracts.PawnShop : r!.contracts.MilestoneBurn;
    const pinned =
      kind === "floor"
        ? (await read(r!, c, "collections", [s!.collectionAddress]))[5]
        : await read(r!, c, "questionHash");
    if (pinned === zeroHash) {
      const authority = await read(
        r!,
        c,
        kind === "floor" ? "owner" : "questionSetter",
      );
      if (authority.toLowerCase() !== e.account?.toLowerCase() || s!.shop.owner.toLowerCase() !== e.account?.toLowerCase())
        throw Error(
          "The question is unset. Its owner/setup authority must configure it first; retain this request id.",
        );
      await walletCheck();
      update("Confirm the one-time question hash in your wallet.");
      await e.send(
        {
          contract: c,
          functionName: "setQuestionHashOnce",
          args:
            kind === "floor"
              ? [s!.collectionAddress, valid.attestation.questionHash]
              : [valid.attestation.questionHash],
          summary: "Pin the verified oracle question hash.",
        },
        () => {},
      );
    }
    if (kind === "floor") {
      const floor = await read(r!, c, "floors", [s!.collectionAddress]);
      if (valid.attestation.issuedAt <= floor[1]) {
        update("Done: this floor or a newer one is already stored.");
        return;
      }
      await walletCheck();
      const fresh = await checked(ev);
      update("Confirm posting the verified floor in your wallet.");
      await e.send(
        {
          contract: c,
          functionName: "submitFloor",
          args: [s!.collectionAddress, fresh.attestation, fresh.signature],
          summary: `Post ${units(fresh.value)} ETH floor.`,
        },
        () => {},
      );
      update("Done: floor posted and chain state refreshed.");
    } else
      update(
        valid.value >= 1000000n * 10n ** 18n
          ? "Market cap verified. The milestone qualifies; review Burn below."
          : "Market cap verified. The $1M milestone has not been reached.",
      );
  }
  async function poll(requestId: string) {
    localStorage.setItem(storageKey + "-id", requestId);
    setId(requestId);
    while (active.current && !cancel.current) {
      update(`Request ${requestId}: waiting for the oracle panel…`);
      const ev = await loadEvidence(requestId);
      if (ev) {
        await post(ev);
        return;
      }
      await new Promise((resolve) => setTimeout(resolve, 10000));
    }
  }
  async function run(fn: () => Promise<void>) {
    setBusy(true);
    setError("");
    cancel.current = false;
    try {
      await fn();
    } catch (x) {
      if (active.current) setError(x instanceof Error ? x.message : String(x));
    } finally {
      if (active.current) setBusy(false);
    }
  }
  return (
    <section
      className="oracle-flow"
      aria-label={kind === "floor" ? "Refresh floor" : "Market cap request"}
    >
      {publicFlow ? (
        <p>Floor older than 26 hours? Buy the floor question on explorer.imd.fun (0.5 IMD), paste the request id here, post it, and collect the 0.001 ETH bounty.</p>
      ) : <p>Buy this question on <a href="https://explorer.imd.fun" target="_blank" rel="noreferrer">explorer.imd.fun</a> (0.5 IMD), then paste the oracle request id below.</p>}
      <p className="break">{question(kind)}</p>
      <button onClick={() => void run(async () => {
        await navigator.clipboard.writeText(question(kind));
        update("Question copied.");
      })}>Copy question</button>
      <p className="muted">Ethereum · uint256 · public panel · at least 5 members and quorum 4 · tolerance at most 5%. Use a validity of at least 93,600 seconds (26 hours). The signed question hash must match the configured hash.</p>
      {kind === "floor" && <p className="muted">Bounty is a pull credit, available once per 24 hours if the reserve is funded. Posting and claiming use ETH gas.</p>}
      <RelayStatus />
      <Field
        label={`${kind === "floor" ? "Floor" : "Market cap"} request id`}
        value={id}
        onChange={(v) => {
          setId(v.trim());
          setEvidence(undefined);
          setCap(undefined);
        }}
        hint="Paste a request UUID bought elsewhere, or resume your saved request."
      />
      <button
        disabled={!e.ready || e.pending || busy || !id}
        onClick={() => void run(() => poll(id))}
      >
        {publicFlow ? "Refresh floor" : kind === "floor" ? "Post floor" : "Verify market cap"}
      </button>
      {busy && (
        <button
          onClick={() => {
            cancel.current = true;
            update("Stopped waiting. Resume using the saved request id.");
          }}
        >
          Stop waiting
        </button>
      )}
      {status && (
        <Notice>
          <span role="status">{status}</span>
        </Notice>
      )}
      {error && (
        <p role="alert" className="error">
          {error}
        </p>
      )}
      {kind === "cap" && (
        <>
          <Pair label="Latest verified market cap">
            {cap === undefined
              ? "Pending evidence"
              : `$${units(cap)} / $1,000,000`}
          </Pair>
          <Action
            label="Burn"
            disabled={
              !evidence ||
              cap === undefined ||
              cap < 1000000n * 10n ** 18n ||
              !s?.burn.balance ||
              s?.burn.burned
            }
            prepare={async () => {
              const valid = await checked(evidence);
              return {
                contract: r!.contracts.MilestoneBurn,
                functionName: "burn",
                args: [valid.attestation, valid.signature],
                summary: `Irreversibly burn the entire ${units(s?.burn.balance)} PAWN vault.`,
              };
            }}
          />
        </>
      )}
    </section>
  );
}
