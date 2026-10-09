import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  decodeAbiParameters,
  hashTypedData,
  recoverAddress,
  zeroAddress,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  packRelay,
  relayParameters,
  oracleTypes,
  IMD_ATTESTER,
  validateEvidence,
  question,
  zeroHash,
  signerMode,
  loadEvidence,
} from "../src/oracle";
const fixture = JSON.parse(
  readFileSync(
    new URL("../../test/fixtures/floor-zero-consumer.json", import.meta.url),
    "utf8",
  ),
);
const golden = JSON.parse(
  readFileSync(
    new URL("../../test/fixtures/site-packed-floor.json", import.meta.url),
    "utf8",
  ),
);
const consumer: Address = "0x0cc05d3b2879e8dfd18e987d1a50008506cc3756";
const normalized = { ...fixture.message, answerType: 3 };
for (const field of [
  "chainId",
  "figure",
  "fromBlock",
  "toBlock",
  "issuedAt",
  "expiresAt",
])
  normalized[field] = BigInt(normalized[field]);

test("site packs the exact golden bytes consumed by Solidity and both consumer verifiers", async () => {
  const packed = packRelay(normalized, fixture.signature);
  assert.equal(packed, golden.packed);
  const [a, sig] = decodeAbiParameters(relayParameters, packed);
  assert.deepEqual(a, normalized);
  assert.equal(sig, fixture.signature);
  const recovered = await recoverAddress({
    hash: hashTypedData({
      domain: fixture.domain,
      types: oracleTypes,
      primaryType: "OracleAttestation",
      message: a,
    }),
    signature: sig,
  });
  assert.equal(recovered.toLowerCase(), IMD_ATTESTER.toLowerCase());
});

test("real explorer floor accepts signed 24-hour lifetime without extending expiry", async () => {
  const e = {
    id: fixture.requestId,
    typed: fixture,
    detail: {
      question: question("floor"),
      questionHash: fixture.message.questionHash,
      answerType: "uint256",
      chainId: 1,
      evidence: "panel",
      toleranceBps: 100,
      signer: fixture.signer,
    },
  };
  const valid = await validateEvidence(
    e,
    "floor",
    consumer,
    consumer,
    fixture.message.questionHash,
    fixture.message.issuedAt,
    "relay",
  );
  assert.equal(valid.attestation.expiresAt, normalized.expiresAt);
  await assert.rejects(
    validateEvidence(
      e,
      "floor",
      consumer,
      consumer,
      fixture.message.questionHash,
      Number(normalized.expiresAt) + 1,
      "relay",
    ),
    /expired/,
  );
  await assert.rejects(
    validateEvidence(
      e,
      "floor",
      consumer,
      IMD_ATTESTER,
      zeroHash,
      fixture.message.issuedAt,
    ),
    /Until the FloorRelay switch/,
  );
});

test("relay mode rejects a forged attester and a different question hash", async () => {
  const account = privateKeyToAccount(`0x${"11".repeat(32)}`);
  const a = { ...normalized, expiresAt: normalized.issuedAt + 93600n };
  const typed = {
    domain: fixture.domain,
    message: a,
    signer: IMD_ATTESTER,
    signature: await account.signTypedData({
      domain: fixture.domain,
      types: oracleTypes,
      primaryType: "OracleAttestation",
      message: a,
    }),
  };
  const e = {
    id: fixture.requestId,
    typed,
    detail: {
      question: question("floor"),
      questionHash: a.questionHash,
      answerType: "uint256",
      chainId: 1,
      evidence: "panel",
      toleranceBps: 100,
      signer: IMD_ATTESTER,
    },
  };
  await assert.rejects(
    validateEvidence(
      e,
      "floor",
      consumer,
      consumer,
      a.questionHash,
      Number(a.issuedAt),
      "relay",
    ),
    /Invalid oracle signature/,
  );
  await assert.rejects(
    validateEvidence(
      e,
      "floor",
      consumer,
      consumer,
      `0x${"ab".repeat(32)}`,
      Number(a.issuedAt),
      "relay",
    ),
    /configured hash/,
  );
  typed.domain = { ...typed.domain, verifyingContract: consumer };
  await assert.rejects(
    validateEvidence(
      e,
      "floor",
      consumer,
      consumer,
      a.questionHash,
      Number(a.issuedAt),
      "relay",
    ),
    /no consumer/,
  );
});

test("signer discovery rejects unknown contracts; EOA remains in direct mode", async () => {
  assert.equal(
    await signerMode({ getCode: async () => "0x" }, IMD_ATTESTER),
    "direct",
  );
  await assert.rejects(
    signerMode({ getCode: async () => "0x60006000" }, consumer),
    /not the verified/,
  );
});

test("request-id flow makes only two public GET requests and rejects invalid ids", async () => {
  const calls: string[] = [];
  const fetcher = (async (url: string, options: RequestInit) => {
    calls.push(url);
    assert.equal(options.method, undefined);
    assert.equal(options.body, undefined);
    return new Response(
      JSON.stringify(calls.length === 1 ? { status: "attested" } : fixture),
    );
  }) as typeof fetch;
  const loaded = await loadEvidence(fixture.requestId, fetcher);
  assert.equal(loaded?.typed.signature, fixture.signature);
  assert.equal(calls.length, 2);
  assert(
    calls.every((url) =>
      url.startsWith("https://api.imd.fun/oracle/requests/"),
    ),
  );
  await assert.rejects(loadEvidence("../purchase", fetcher), /UUID/);
});
