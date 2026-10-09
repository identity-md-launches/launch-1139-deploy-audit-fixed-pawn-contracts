import { useEffect, useRef, useState } from "react";
import { useEngine, read } from "./engine";
import { Action, Field, Notice, Pair, units, when } from "./components";
import {
  loadEvidence,
  validateEvidence,
  signerMode,
  question,
  zeroHash,
  evidenceDeadline,
  BURN_MILESTONE,
  type Kind,
} from "./oracle";
import { RelayStatus } from "./relay-setup";

type Inspection = {
  valid: Awaited<ReturnType<typeof validateEvidence>>;
  governed: string;
  accepted: boolean;
  authority: string;
  deadline: number;
  chainTime: number;
  observedAt: number;
  alreadyPosted: boolean;
};

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
  const [id, setId] = useState("");
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");
  const [evidence, setEvidence] = useState<any>();
  const [inspection, setInspection] = useState<Inspection>();
  const [now, setNow] = useState(Date.now);
  const generation = useRef(0);
  const storageKey = `pawn-oracle-${e.account}-${kind}`;
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => {
      window.clearInterval(timer);
      generation.current++;
    };
  }, []);
  useEffect(() => {
    generation.current++;
    setId(localStorage.getItem(storageKey + "-id") ?? "");
    setEvidence(undefined);
    setInspection(undefined);
    setStatus("");
    setError("");
    setBusy(false);
  }, [storageKey]);

  async function inspect(ev: any): Promise<Inspection> {
    if (!r || !s) throw Error("Refresh chain state before fetching an answer.");
    const consumer =
      kind === "floor" ? r.contracts.PawnShop : r.contracts.MilestoneBurn;
    const [block, signer, governed, approved, authority, floor] =
      await Promise.all([
        r.client.getBlock(),
        read(r, r.contracts.PawnShop, "oracleSigner"),
        kind === "floor"
          ? read(r, consumer, "collections", [s.collectionAddress]).then(
              (x) => x[5],
            )
          : read(r, consumer, "questionHash"),
        kind === "floor"
          ? read(r, consumer, "approvedQuestionHash", [s.collectionAddress])
          : zeroHash,
        read(r, consumer, kind === "floor" ? "owner" : "questionSetter"),
        kind === "floor"
          ? read(r, consumer, "floors", [s.collectionAddress])
          : undefined,
      ]);
    // Verify the signed evidence independently of admission. Admission is checked
    // separately below and again before preparing any posting/burning transaction.
    const valid = await validateEvidence(
      ev,
      kind,
      consumer.address,
      signer,
      zeroHash,
      Number(block.timestamp),
      await signerMode(r.client, signer),
    );
    if (
      kind === "floor" &&
      (valid.attestation.fromBlock > valid.attestation.toBlock ||
        valid.attestation.toBlock > block.number ||
        block.number - valid.attestation.toBlock > 7800n)
    )
      throw Error(
        "The floor answer's block window is invalid or over 7,800 blocks old. Fetch a fresh request.",
      );
    const hash = valid.attestation.questionHash.toLowerCase();
    return {
      valid,
      governed,
      authority,
      accepted:
        governed !== zeroHash &&
        (hash === governed.toLowerCase() ||
          (kind === "floor" && hash === approved.toLowerCase())),
      deadline: evidenceDeadline(kind, valid.attestation),
      chainTime: Number(block.timestamp),
      observedAt: Date.now(),
      alreadyPosted: !!floor && valid.attestation.issuedAt <= floor[1],
    };
  }
  useEffect(() => {
    if (!evidence) return;
    let live = true;
    void inspect(evidence)
      .then((value) => {
        if (live) {
          setInspection(value);
          setError("");
        }
      })
      .catch((x) => {
        if (live) setError(x instanceof Error ? x.message : String(x));
      });
    return () => {
      live = false;
    };
  }, [evidence, s?.at]);

  async function fetchAnswer() {
    const run = ++generation.current;
    setBusy(true);
    setError("");
    setStatus("");
    setEvidence(undefined);
    setInspection(undefined);
    try {
      localStorage.setItem(storageKey + "-id", id);
      while (generation.current === run) {
        setStatus("Fetching the oracle attestation…");
        const ev = await loadEvidence(id);
        if (generation.current !== run) return;
        if (ev) {
          const checked = await inspect(ev);
          if (generation.current !== run) return;
          setInspection(checked);
          setEvidence(ev);
          setStatus(
            "Attestation verified. Review the answer and next action below.",
          );
          return;
        }
        setStatus(
          "Waiting for the oracle panel. You can stop and resume with this request id.",
        );
        await new Promise((resolve) => window.setTimeout(resolve, 10000));
      }
    } catch (x) {
      if (generation.current === run) {
        setError(x instanceof Error ? x.message : String(x));
        setStatus("");
      }
    } finally {
      if (generation.current === run) setBusy(false);
    }
  }
  const hash = inspection?.valid.attestation.questionHash;
  const authority =
    !!e.account &&
    e.account.toLowerCase() === inspection?.authority.toLowerCase();
  const qualifies = inspection && inspection.valid.value >= BURN_MILESTONE;
  const remaining = inspection
    ? Math.max(
        0,
        inspection.deadline -
          inspection.chainTime -
          Math.max(0, Math.floor((now - inspection.observedAt) / 1000)),
      )
    : 0;
  const expired = !!inspection && remaining <= 0;
  const blocked = busy || expired || !!error;
  const transactionExpiry = (checked: Inspection) =>
    checked.observedAt + (checked.deadline - checked.chainTime) * 1000;

  return (
    <section
      className="oracle-flow"
      aria-label={kind === "floor" ? "Refresh floor" : "Market cap request"}
    >
      <p>
        {publicFlow ? "Refresh the floor by buying" : "Buy"} this question on{" "}
        <a href="https://explorer.imd.fun" target="_blank" rel="noreferrer">
          explorer.imd.fun
        </a>{" "}
        (0.5 IMD), then paste the request id below.
      </p>
      <p className="break">{question(kind)}</p>
      <button
        type="button"
        onClick={() => {
          void navigator.clipboard
            .writeText(question(kind))
            .then(() => setStatus("Question copied."))
            .catch(() =>
              setError(
                "Could not copy. Select and copy the question text above.",
              ),
            );
        }}
      >
        Copy question
      </button>
      <p className="muted">
        Ethereum · uint256 · public panel · at least 5 members and quorum 4 ·
        tolerance at most 5%. Request an answer signed with no consumer while
        FloorRelay is active.
      </p>
      {kind === "floor" ? (
        <p className="muted">
          The owner approves each new request hash immediately. After approval,
          anyone can post. Floors remain fresh for at most 26 hours, or until
          their signed expiry. A funded reserve pays a 0.001 ETH pull credit at
          most once per 24 hours. Posting and claiming use ETH gas.
        </p>
      ) : (
        <p className="muted">
          At $1M or above, the question setter pins this answer, then anyone can
          burn. The answer must remain unexpired and under 1 hour old when the
          burn is mined.
        </p>
      )}
      <RelayStatus />
      <Field
        label={`${kind === "floor" ? "Floor" : "Market cap"} request id`}
        value={id}
        onChange={(value) => {
          generation.current++;
          setBusy(false);
          setId(value.trim());
          setEvidence(undefined);
          setInspection(undefined);
          setError("");
          setStatus("");
        }}
        hint="Paste a request UUID bought elsewhere, or resume your saved request. Fetching is read-only."
      />
      <button
        type="button"
        disabled={!r || !s || busy || e.pending || !id}
        onClick={() => void fetchAnswer()}
      >
        {busy
          ? "Fetching attestation…"
          : publicFlow
            ? "Refresh floor"
            : kind === "floor"
              ? "Fetch floor attestation"
              : "Verify market cap"}
      </button>
      {busy && (
        <button
          type="button"
          onClick={() => {
            generation.current++;
            setBusy(false);
            setStatus("Stopped waiting. Resume using the saved request id.");
          }}
        >
          Stop waiting
        </button>
      )}
      <p role="status">{status}</p>
      {error && (
        <p role="alert" className="error">
          {error}
        </p>
      )}
      {inspection && (
        <div className="oracle-answer">
          <Pair
            label={
              kind === "floor" ? "Verified floor" : "Latest verified market cap"
            }
          >
            {kind === "floor"
              ? `${units(inspection.valid.value)} ETH`
              : `$${units(inspection.valid.value)} / $1,000,000`}
          </Pair>
          <Pair label="Answer issued">
            {when(inspection.valid.attestation.issuedAt)}
          </Pair>
          <Pair label="Request question hash">
            <code className="break">{hash}</code>
          </Pair>
          {kind === "cap" && (
            <>
              <Pair label="Time left to burn">
                <span role="timer" aria-live="off">
                  {expired
                    ? "Expired — fetch a fresh answer"
                    : `${Math.floor(remaining / 60)}m ${String(remaining % 60).padStart(2, "0")}s`}
                </span>
              </Pair>
              <p className="muted">
                Deadline: {when(BigInt(inspection.deadline))}. The earlier of
                signed expiry and 1 hour after issue applies.
              </p>
              {!qualifies && (
                <Notice>
                  The $1M milestone has not been reached. No pin or burn is
                  available for this answer.
                </Notice>
              )}
              {s?.burn.burned && (
                <Notice>The one-time burn has already completed.</Notice>
              )}
            </>
          )}
          {expired && (
            <Notice tone="warning">
              This answer is no longer usable. Paste a fresh request id and
              fetch its attestation.
            </Notice>
          )}
          {kind === "floor" && inspection.alreadyPosted ? (
            <Notice>This floor or a newer one is already stored.</Notice>
          ) : (
            (kind === "floor" || (qualifies && !s?.burn.burned)) && (
              <>
                {!inspection.accepted &&
                  !expired &&
                  (authority ? (
                    <>
                      {kind === "floor" && inspection.governed === zeroHash ? (
                        <Notice tone="warning">
                          The governed floor question is unset. Configure it in
                          Governance before approving this request.
                        </Notice>
                      ) : (
                        <Action
                          key={`admit-${hash}-${inspection.governed}`}
                          label={
                            kind === "floor"
                              ? "Approve this hash"
                              : "Pin this answer"
                          }
                          disabled={blocked}
                          prepare={async () => {
                            const fresh = await inspect(evidence);
                            if (
                              fresh.authority.toLowerCase() !==
                              e.account?.toLowerCase()
                            )
                              throw Error(
                                "Connect the current approval authority and fetch the answer again.",
                              );
                            if (
                              kind === "cap" &&
                              fresh.valid.value < BURN_MILESTONE
                            )
                              throw Error(
                                "The $1M milestone has not been reached.",
                              );
                            return {
                              contract:
                                kind === "floor"
                                  ? r!.contracts.PawnShop
                                  : r!.contracts.MilestoneBurn,
                              functionName:
                                kind === "floor"
                                  ? "approveQuestionHash"
                                  : fresh.governed === zeroHash
                                    ? "setQuestionHashOnce"
                                    : "replaceQuestionHash",
                              args:
                                kind === "floor"
                                  ? [
                                      s!.collectionAddress,
                                      fresh.valid.attestation.questionHash,
                                    ]
                                  : [fresh.valid.attestation.questionHash],
                              expiresAt: transactionExpiry(fresh),
                              summary:
                                kind === "floor"
                                  ? `Immediately approve this floor request hash: ${hash}. The governed pin is unchanged.`
                                  : `Pin this $${units(fresh.valid.value)} answer: ${hash}. ${fresh.governed === zeroHash ? "Set the first burn question hash." : "Replace the previous burn question hash."} This does not burn tokens.`,
                            };
                          }}
                        />
                      )}
                    </>
                  ) : (
                    <Notice tone="warning">
                      {kind === "floor"
                        ? "Waiting for owner approval"
                        : "Waiting for the question setter to pin this answer"}
                      . Request hash: <code className="break">{hash}</code>.
                      Refresh the attestation after approval.
                    </Notice>
                  ))}
                {inspection.accepted && (
                  <>
                    <Notice>
                      {kind === "floor"
                        ? "This hash is approved. Review Post floor below."
                        : "This answer is pinned. Review Burn below."}
                    </Notice>
                    <Action
                      key={`post-${hash}`}
                      label={kind === "floor" ? "Post floor" : "Burn"}
                      disabled={
                        blocked ||
                        (kind === "cap" && (!s?.burn.balance || s?.burn.burned))
                      }
                      reason={
                        kind === "cap" && !s?.burn.balance
                          ? "The burn vault is empty. Fund it before burning."
                          : undefined
                      }
                      prepare={async () => {
                        const fresh = await inspect(evidence);
                        if (!fresh.accepted)
                          throw Error(
                            "This request hash is no longer approved. Refresh the attestation and ask its approval authority.",
                          );
                        if (fresh.alreadyPosted)
                          throw Error(
                            "This floor or a newer one is already stored. Refresh chain state.",
                          );
                        return {
                          contract:
                            kind === "floor"
                              ? r!.contracts.PawnShop
                              : r!.contracts.MilestoneBurn,
                          functionName:
                            kind === "floor" ? "submitFloor" : "burn",
                          args:
                            kind === "floor"
                              ? [
                                  s!.collectionAddress,
                                  fresh.valid.attestation,
                                  fresh.valid.signature,
                                ]
                              : [
                                  fresh.valid.attestation,
                                  fresh.valid.signature,
                                ],
                          expiresAt: transactionExpiry(fresh),
                          summary:
                            kind === "floor"
                              ? `Post the verified ${units(fresh.valid.value)} ETH floor.`
                              : `Irreversibly burn the entire ${units(s?.burn.balance)} PAWN vault using this $${units(fresh.valid.value)} answer. This can happen only once.`,
                        };
                      }}
                    />
                  </>
                )}
              </>
            )
          )}
        </div>
      )}
    </section>
  );
}
