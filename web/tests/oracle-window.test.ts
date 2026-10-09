import { test } from "node:test";
import assert from "node:assert/strict";
import { privateKeyToAccount } from "viem/accounts";
import { encodeAbiParameters, parseAbiParameters, type Address } from "viem";
import {
  CAP_QUESTION,
  BURN_MILESTONE,
  BURN_MAX_AGE,
  evidenceDeadline,
  oracleTypes,
  validateEvidence,
  zeroHash,
} from "../src/oracle";
import deployment from "../deployment.json";
const consumer = deployment.contracts.find((c) => c.name === "MilestoneBurn")!
  .address as Address;
// Public deterministic fixture key; never a wallet used outside tests.
const signer = privateKeyToAccount(`0x${"11".repeat(32)}`);
const issuedAt = 1800000000;
async function evidence(value = BURN_MILESTONE, lifetime = 86400) {
  const id = "62702d2a-1a38-4543-93cc-7ece5ac20a66";
  const message = {
    requestId: `0x${id.replaceAll("-", "")}${"0".repeat(32)}`,
    questionHash: `0x${"ab".repeat(32)}`,
    chainId: 1n,
    answerType: 3,
    answer: encodeAbiParameters(parseAbiParameters("uint256"), [value]),
    figure: 0n,
    fromBlock: 26155000n,
    toBlock: 26156000n,
    blockHash: `0x${"cd".repeat(32)}`,
    panelJobId: `0x${"ef".repeat(32)}`,
    panelSize: 5,
    quorum: 4,
    agreed: 4,
    issuedAt: BigInt(issuedAt),
    expiresAt: BigInt(issuedAt + lifetime),
  };
  const domain = {
    name: "IdentityMD Oracle",
    version: "2",
    chainId: 1,
    verifyingContract: consumer,
  };
  return {
    id,
    detail: {
      question: CAP_QUESTION,
      questionHash: message.questionHash,
      answerType: "uint256",
      chainId: 1,
      evidence: "panel",
      toleranceBps: 500,
      signer: signer.address,
    },
    typed: {
      domain,
      message,
      signer: signer.address,
      signature: await signer.signTypedData({
        domain,
        types: oracleTypes,
        primaryType: "OracleAttestation",
        message,
      }),
    },
  };
}
const verify = (e: any, now: number, pinned = zeroHash) =>
  validateEvidence(e, "cap", consumer, signer.address, pinned, now);
test("24-hour TWAP question is exact; a valid unpinned answer can be inspected before admission", async () => {
  assert.equal(
    CAP_QUESTION,
    "What is the fully diluted market cap of the PAWN token (0x4f2bacee5f2e7ce3f48dfbd635d96e9a8fcbe478, Ethereum mainnet), computed as total supply times its 24-hour time-weighted average price from its Uniswap v4 ETH pool, converted to USD at the current ETH price? Answer as a uint256 in USD with 18 decimals.",
  );
  const e = await evidence();
  assert.equal((await verify(e, issuedAt)).value, BURN_MILESTONE);
  await assert.rejects(
    verify(e, issuedAt, `0x${"cd".repeat(32)}`),
    /configured hash/,
  );
  e.detail.question = CAP_QUESTION.replace(
    "its 24-hour time-weighted average price",
    "the spot price",
  );
  await assert.rejects(verify(e, issuedAt), /question/);
});
test("burn accepts the contract's exact one-hour boundary and rejects older/future answers", async () => {
  const e = await evidence();
  assert.equal(
    (await verify(e, issuedAt + BURN_MAX_AGE)).value,
    BURN_MILESTONE,
  );
  await assert.rejects(
    verify(e, issuedAt + BURN_MAX_AGE + 1),
    /over 1 hour old/,
  );
  await assert.rejects(verify(e, issuedAt - 1), /future/);
  assert.equal(
    evidenceDeadline("cap", e.typed.message),
    issuedAt + BURN_MAX_AGE,
  );
});
test("earlier signed expiry wins; below-milestone values retain exact uint256 precision", async () => {
  const e = await evidence(BURN_MILESTONE - 1n, 120);
  assert.equal((await verify(e, issuedAt + 119)).value, BURN_MILESTONE - 1n);
  assert.equal(evidenceDeadline("cap", e.typed.message), issuedAt + 120);
  await assert.rejects(verify(e, issuedAt + 121), /expired/);
});
test("tampered answers never become approvable evidence", async () => {
  const e = await evidence();
  e.typed.message.answer = encodeAbiParameters(parseAbiParameters("uint256"), [
    BURN_MILESTONE * 2n,
  ]);
  await assert.rejects(verify(e, issuedAt), /signature/);
});
