import { test } from "node:test";
import assert from "node:assert/strict";
import { encodeAbiParameters, parseAbiParameters } from "viem";
import { tradingFees } from "../src/trading-fees";
import deployment from "../deployment.json";
const token = deployment.contracts.find((c) => c.name === "LaunchToken")!,
  shop = deployment.tokenLaunch.contracts.find((c) => c.name === "PawnShop")!,
  burn = deployment.tokenLaunch.contracts.find(
    (c) => c.name === "MilestoneBurn",
  )!;
const factory = "0xff03410d0fe5fa8f7f59f743de35e333d9857120",
  distributor = "0x4f026ddbaee3360b8ddfdcb750511081a01e5b68",
  recipient = "0x23e5d7a7b4ea19530ec39c67cd46aa8c10d15acf";
function fixture() {
  const receipt: any = {
    status: "success",
    blockNumber: BigInt(shop.blockNumber),
    to: factory,
    logs: [
      { address: token.address },
      {
        address: factory,
        topics: [
          "0x" + "ab".repeat(32),
          "0x" + 994n.toString(16).padStart(64, "0"),
          "0x" + "0".repeat(24) + token.address.slice(2),
        ],
        data: encodeAbiParameters(parseAbiParameters("address,address[]"), [
          distributor,
          [shop.address as any, burn.address as any],
        ]),
      },
    ],
  };
  const key: any = { ...deployment.poolKey };
  const r: any = {
    deployment,
    contracts: {
      PawnShop: deployment.contracts.find((c) => c.name === "PawnShop"),
      MilestoneBurn: deployment.contracts.find(
        (c) => c.name === "MilestoneBurn",
      ),
      LaunchToken: token,
    },
    client: {
      async getTransactionReceipt({ hash }: any) {
        assert.equal(
          hash,
          token.txHash,
          "Trading fees use the original token launch transaction",
        );
        return receipt;
      },
      async getCode() {
        return "0x6000";
      },
      async readContract() {
        return [key, -887220, 184200, recipient];
      },
      async simulateContract(call: any) {
        assert.equal(call.functionName, "claimFees");
        assert.equal(call.args[0], 994n);
        return { result: [123n, 456n] };
      },
    },
  };
  return { r, receipt, key };
}
test("discover actual factory and distributor from original launch receipt; return pending trading fees", async () => {
  const { r } = fixture();
  const fee = await tradingFees(r, recipient);
  assert.equal(fee.factory.address, factory);
  assert.equal(fee.distributor.toLowerCase(), distributor);
  assert.deepEqual(fee.amounts, [123n, 456n]);
  assert.equal(fee.recipient, recipient);
});
test("refuse wrong receipt, wrong pool and missing child bindings before enabling trading claims", async () => {
  let f = fixture();
  f.receipt.blockNumber++;
  await assert.rejects(tradingFees(f.r, recipient), /provenance/);
  f = fixture();
  f.key.fee = 3000;
  await assert.rejects(tradingFees(f.r, recipient), /pool/);
  f = fixture();
  f.receipt.logs[1].data = encodeAbiParameters(
    parseAbiParameters("address,address[]"),
    [distributor, []],
  );
  await assert.rejects(tradingFees(f.r, recipient), /bindings/);
});
