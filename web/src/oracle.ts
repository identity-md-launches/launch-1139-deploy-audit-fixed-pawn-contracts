import {
  decodeAbiParameters,
  getAddress,
  hashTypedData,
  parseAbiParameters,
  recoverAddress,
  encodeAbiParameters,
  keccak256,
  zeroAddress,
  type Address,
  type Hex,
} from "viem";
import relayArtifact from "./floor-relay.json";
export const IMD_ATTESTER: Address = "0x5598aa9146215bc13eb26f2c692ad1461fd32982";
export const API = "https://api.imd.fun";
export const FLOOR_QUESTION =
  "What is the current floor price, in wei, of the identity.md NFT collection at 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D on Ethereum mainnet, defined as the lowest active listing on OpenSea or Blur at the time of answering? Answer as a uint256 in wei.";
export const CAP_QUESTION =
  "What is the fully diluted market cap of the PAWN token (0x4f2bacee5f2e7ce3f48dfbd635d96e9a8fcbe478, Ethereum mainnet), computed as total supply times the spot price from its Uniswap v4 ETH pool, converted to USD at the current ETH price? Answer as a uint256 in USD with 18 decimals.";
export type Kind = "floor" | "cap";
export const oracleTypes = {
  OracleAttestation: [
    ["requestId", "bytes32"],
    ["chainId", "uint256"],
    ["questionHash", "bytes32"],
    ["answerType", "uint8"],
    ["answer", "bytes"],
    ["figure", "uint256"],
    ["fromBlock", "uint64"],
    ["toBlock", "uint64"],
    ["blockHash", "bytes32"],
    ["panelJobId", "bytes32"],
    ["panelSize", "uint16"],
    ["quorum", "uint16"],
    ["agreed", "uint16"],
    ["issuedAt", "uint64"],
    ["expiresAt", "uint64"],
  ].map(([name, type]) => ({ name, type })),
};
export const relayParameters = [
  { type: "tuple", components: oracleTypes.OracleAttestation },
  { type: "bytes" },
] as const;
export function packRelay(attestation: any, signature: Hex): Hex {
  return encodeAbiParameters(relayParameters, [attestation, signature]);
}
export function isFloorRelay(code?: Hex) {
  return !!code && code !== "0x" && keccak256(code) === relayArtifact.runtimeCodeHash;
}
// Discover the actual governed signer, without inventing a relay deployment address.
export async function signerMode(client: { getCode: (args: { address: Address }) => Promise<Hex | undefined> }, signer: Address) {
  const code = await client.getCode({ address: signer });
  if (isFloorRelay(code)) return "relay" as const;
  if (!code || code === "0x") return "direct" as const;
  throw Error("The governed contract attester is not the verified FloorRelay build.");
}
export const zeroHash = `0x${"0".repeat(64)}`;
export const question = (kind: Kind) =>
  kind === "floor" ? FLOOR_QUESTION : CAP_QUESTION;
export function uuid(id: string) {
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)
  )
    throw Error("Enter an oracle request UUID.");
  return id.toLowerCase();
}
export async function apiJSON(
  path: string,
  init?: RequestInit,
  fetcher: typeof fetch = fetch,
) {
  const response = await fetcher(API + path, {
    ...init,
    signal: init?.signal ?? AbortSignal.timeout(20000),
  });
  const body = await response.json();
  if (!response.ok)
    throw Error(
      `${response.status}: ${body.detail ?? body.error ?? "Oracle service unavailable"}`,
    );
  return body;
}
export async function loadEvidence(id: string, fetcher: typeof fetch = fetch) {
  id = uuid(id);
  const detail = await apiJSON(`/oracle/requests/${id}`, undefined, fetcher);
  if (
    ["failed", "refused", "cancelled"].includes(detail.status) ||
    detail.failure
  )
    throw Error(
      `Oracle failed: ${typeof detail.failure === "string" ? detail.failure : detail.status}`,
    );
  if (detail.status !== "attested") return undefined;
  const typed = await apiJSON(
    `/oracle/requests/${id}/attestation`,
    undefined,
    fetcher,
  );
  return { id, detail, typed };
}
export async function validateEvidence(
  e: any,
  kind: Kind,
  consumer: Address,
  signer: Address,
  pinned: string,
  now: number,
  mode: "direct" | "relay" = "direct",
) {
  const expectedSigner = mode === "relay" ? IMD_ATTESTER : signer;
  const signingConsumer = mode === "relay" ? zeroAddress : consumer;
  const d = e.detail,
    t = e.typed,
    m = t.message,
    domain = t.domain;
  if (
    d.question !== question(kind) ||
    d.answerType !== "uint256" ||
    d.chainId !== 1 ||
    d.evidence !== "panel" ||
    !Number.isInteger(d.toleranceBps) ||
    d.toleranceBps > 500 ||
    d.toleranceBps < 0
  )
    throw Error(
      "Request question, public panel evidence, chain or tolerance does not match.",
    );
  if (
    domain?.name !== "IdentityMD Oracle" ||
    domain.version !== "2" ||
    Number(domain.chainId) !== 1 ||
    domain.verifyingContract?.toLowerCase() !== signingConsumer.toLowerCase()
  )
    throw Error(
      mode === "relay"
        ? "FloorRelay requires an answer signed with no consumer on chain 1."
        : "Until the FloorRelay switch lands, only answers signed for this contract are accepted.",
    );
  if (
    t.signer?.toLowerCase() !== expectedSigner.toLowerCase() ||
    d.signer?.toLowerCase() !== expectedSigner.toLowerCase()
  )
    throw Error("Attester does not match the governed on-chain signer.");
  const a: any = {
    ...m,
    answerType: m.answerType === "uint256" ? 3 : Number(m.answerType),
  };
  for (const k of [
    "chainId",
    "figure",
    "fromBlock",
    "toBlock",
    "issuedAt",
    "expiresAt",
  ])
    a[k] = BigInt(m[k]);
  const requestHash = `0x${uuid(e.id).replaceAll("-", "")}${"0".repeat(32)}`;
  if (
    a.requestId?.toLowerCase() !== requestHash ||
    a.questionHash !== d.questionHash ||
    !/^0x[0-9a-f]{64}$/i.test(a.questionHash) ||
    a.questionHash === zeroHash
  )
    throw Error("Request id or question hash mismatch.");
  if (
    pinned !== zeroHash &&
    a.questionHash.toLowerCase() !== pinned.toLowerCase()
  )
    throw Error(
      "This question hash differs from the configured hash. The owner must approve this request's hash with approveQuestionHash (floor) or re-pin with replaceQuestionHash (burn) first.",
    );
  if (
    a.chainId !== 1n ||
    a.answerType !== 3 ||
    !/^0x[0-9a-f]{64}$/i.test(a.answer) ||
    a.panelSize < 5 ||
    a.quorum < 4 ||
    a.agreed < a.quorum ||
    a.agreed > a.panelSize ||
    a.quorum > a.panelSize
  )
    throw Error("Invalid typed answer or panel consensus.");
  if (
    a.issuedAt > BigInt(now) ||
    BigInt(now) - a.issuedAt > 93600n ||
    a.expiresAt < BigInt(now)
  )
    throw Error("Attestation is stale, expired or issued in the future.");
  // The contract accepts any signed lifetime and is never fresh past the signed expiry.
  if (kind === "floor" && a.expiresAt <= a.issuedAt)
    throw Error("Floor attestation must expire after it was issued.");
  const digest = hashTypedData({
    domain: {
      name: "IdentityMD Oracle",
      version: "2",
      chainId: 1,
      verifyingContract: signingConsumer,
    },
    types: oracleTypes,
    primaryType: "OracleAttestation",
    message: a,
  });
  if (
    (
      await recoverAddress({ hash: digest, signature: t.signature })
    ).toLowerCase() !== expectedSigner.toLowerCase()
  )
    throw Error("Invalid oracle signature.");
  const [value] = decodeAbiParameters(parseAbiParameters("uint256"), a.answer);
  if (kind === "floor" && value === 0n) throw Error("Floor must be positive.");
  if (!/^0x[0-9a-f]{130}$/i.test(t.signature)) throw Error("Expected a 65-byte IMD signature.");
  return { attestation: a, signature: mode === "relay" ? packRelay(a, t.signature) : t.signature as Hex, value };
}
