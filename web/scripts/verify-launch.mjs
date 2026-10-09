// Read-only mainnet verification. --write updates only the frontend/keeper handoff.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import {
  createPublicClient,
  custom,
  toFunctionSelector,
  keccak256,
} from "viem";
import { root, web, json, abiHash } from "./common.mjs";

const previous = json(resolve(web, "deployment.json"));
const input = resolve(root, ".imd/reads/deployment.json");
const pinned = existsSync(input)
  ? json(input)
  : {
      ...previous,
      contracts: [
        ...previous.contracts.filter((c) => !c.discoveredFrom),
        previous.standaloneLockDiscount,
      ],
    };
const networkInput = resolve(root, ".imd/reads/network.json");
const network = json(
  existsSync(networkInput) ? networkInput : resolve(web, "network.json"),
);
const rpc = network.network.rpcUrls[0];
const client = createPublicClient({
  transport: custom(
    {
      request: async ({ method, params }) => {
        const body = JSON.parse(
          execFileSync(
            "curl",
            [
              "--fail-with-body",
              "--silent",
              "--show-error",
              "--max-time",
              "25",
              rpc,
              "-H",
              "Content-Type: application/json",
              "--data-binary",
              JSON.stringify({
                jsonrpc: "2.0",
                id: 1,
                method,
                params: params ?? [],
              }),
            ],
            { encoding: "utf8" },
          ),
        );
        if (body.error) throw Error(JSON.stringify(body.error));
        return body.result;
      },
    },
    { retryCount: 0 },
  ),
});
assert.equal(await client.getChainId(), 1);
const blockFlag = process.argv.indexOf("--block");
const blockNumber =
  blockFlag >= 0
    ? BigInt(process.argv[blockFlag + 1])
    : await client.getBlockNumber();
const block = await client.getBlock({ blockNumber });
const abi = (name) => json(resolve(root, "docs/abi", name + ".json"));
const primary = (name) => pinned.contracts.find((c) => c.name === name);
const shop = primary("PawnShop").address;
const read = (name, address, functionName, args = []) =>
  client.readContract({
    address,
    abi: abi(name),
    functionName,
    args,
    blockNumber,
  });
const derived = [];
for (const [name, getter] of [
  ["LendingPool", "lendingPool"],
  ["LockDiscount", "discountModule"],
  ["VaultFactory", "vaultFactory"],
]) {
  derived.push({
    name,
    blockNumber: primary("PawnShop").blockNumber,
    txHash: primary("PawnShop").txHash,
    address: (await read("PawnShop", shop, getter)).toLowerCase(),
    abiHash: abiHash(abi(name)),
    discoveredFrom: { address: shop, getter, blockNumber: Number(blockNumber) },
  });
}
const token = previous.contracts.find((c) => c.name === "LaunchToken");
assert.equal(
  token.address.toLowerCase(),
  "0x4f2bacee5f2e7ce3f48dfbd635d96e9a8fcbe478",
);
const contracts = [
  token,
  ...["FloorRelay", "PawnShop", "MilestoneBurn"].map(primary),
  ...derived,
];
const report = {
  checkedAt: new Date().toISOString(),
  rpc,
  chainId: 1,
  blockNumber: Number(blockNumber),
  blockHash: block.hash,
  sourceCommit: pinned.sourceCommit,
  mode: "Read-only eth_chainId, eth_getBlockByNumber, eth_getCode and eth_call; no wallet, simulation or broadcast",
  contracts: [],
  state: {},
  spareLockDiscount: primary("LockDiscount"),
};
for (const contract of contracts) {
  const name = contract.name;
  const bytes = readFileSync(resolve(root, "docs/abi", name + ".json"));
  assert(
    bytes.equals(
      execFileSync(
        "git",
        ["show", `${pinned.sourceCommit}:docs/abi/${name}.json`],
        { cwd: root },
      ),
    ),
    name + " ABI differs from pinned commit",
  );
  assert.equal(
    abiHash(abi(name)),
    contract.abiHash,
    name + " canonical ABI hash",
  );
  const code = await client.getCode({ address: contract.address, blockNumber });
  assert(code && code !== "0x", name + " has no code");
  const functions = abi(name).filter((x) => x.type === "function");
  const missing = functions.filter(
    (fn) => !code.includes(toFunctionSelector(fn).slice(2)),
  );
  assert.deepEqual(
    missing,
    [],
    name + " ABI selectors missing from deployed runtime",
  );
  report.contracts.push({
    ...contract,
    codeBytes: (code.length - 2) / 2,
    runtimeCodeHash: keccak256(code),
    checkedFunctionSelectors: functions.length,
  });
}
const child = (name) => derived.find((c) => c.name === name).address;
assert.notEqual(
  child("LockDiscount"),
  primary("LockDiscount").address.toLowerCase(),
  "Spare must not be the active module",
);
for (const name of ["LendingPool", "LockDiscount", "VaultFactory"]) {
  assert.equal(
    (await read(name, child(name), "pawnShop")).toLowerCase(),
    shop.toLowerCase(),
  );
}
for (const fn of [
  "owner",
  "newLoansPaused",
  "oracleSigner",
  "pawnToken",
  "bountyReserve",
  "nextLoanId",
  "IDENTITY_COLLECTION",
  "IDENTITY_QUESTION_HASH",
])
  report.state[fn] = await read("PawnShop", shop, fn);
assert.equal(report.state.pawnToken.toLowerCase(), token.address.toLowerCase());
assert.equal(
  report.state.oracleSigner.toLowerCase(),
  primary("FloorRelay").address.toLowerCase(),
);
assert.equal(
  (
    await read("LockDiscount", child("LockDiscount"), "pawnToken")
  ).toLowerCase(),
  token.address.toLowerCase(),
);
assert.equal(
  (await read("LendingPool", child("LendingPool"), "asset")).toLowerCase(),
  "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
);
assert.equal(
  report.contracts.find((c) => c.name === "FloorRelay").runtimeCodeHash,
  json(resolve(web, "src/floor-relay.json")).runtimeCodeHash,
);
report.state.collection = report.state.IDENTITY_COLLECTION;
for (const [key, fn] of [
  ["collectionConfig", "collections"],
  ["approvedQuestionHash", "approvedQuestionHash"],
  ["floor", "floors"],
  ["floorFresh", "floorFresh"],
])
  report.state[key] = await read("PawnShop", shop, fn, [
    report.state.collection,
  ]);
report.state.pool = {};
for (const fn of [
  "totalAssets",
  "depositCap",
  "idleAssets",
  "totalBorrowed",
  "shortfallReserve",
])
  report.state.pool[fn] = await read("LendingPool", child("LendingPool"), fn);
report.state.burn = {};
for (const fn of [
  "burned",
  "questionHash",
  "questionSetter",
  "burnedAmount",
  "MAX_ATTESTATION_AGE",
  "pawnShop",
  "pawnToken",
])
  report.state.burn[fn] = await read(
    "MilestoneBurn",
    primary("MilestoneBurn").address,
    fn,
  );
assert.equal(report.state.burn.pawnShop.toLowerCase(), shop.toLowerCase());
assert.equal(
  report.state.burn.pawnToken.toLowerCase(),
  token.address.toLowerCase(),
);
assert.equal(report.state.burn.MAX_ATTESTATION_AGE, 3600n);
const stringify = (v) =>
  JSON.stringify(v, (_, x) => (typeof x === "bigint" ? String(x) : x), 2) +
  "\n";
mkdirSync(resolve(root, "artifacts"), { recursive: true });
writeFileSync(
  resolve(root, "artifacts/mainnet-verification.json"),
  stringify(report),
);
mkdirSync(resolve(root, "docs/frontend/relaunch"), { recursive: true });
writeFileSync(
  resolve(root, "docs/frontend/relaunch/mainnet-verification.json"),
  stringify(report),
);
if (process.argv.includes("--write")) {
  const handoff = {
    ...pinned,
    poolKey: previous.poolKey,
    tokenLaunch: previous.tokenLaunch ?? {
      launchId: previous.launchId,
      sourceCommit: previous.sourceCommit,
      repoUrl: previous.repoUrl,
      attestationHash: previous.attestationHash,
      contracts: previous.contracts,
    },
    contracts,
    standaloneLockDiscount: primary("LockDiscount"),
    verification: {
      blockNumber: Number(blockNumber),
      blockHash: block.hash,
      rpc,
      report: "docs/frontend/relaunch/mainnet-verification.json",
    },
  };
  writeFileSync(resolve(web, "deployment.json"), stringify(handoff));
  const keeper = json(resolve(root, "keeper/config.json"));
  keeper.addresses = Object.fromEntries(
    contracts.map((c) => [c.name, c.address]),
  );
  writeFileSync(resolve(root, "keeper/config.json"), stringify(keeper));
}
console.log(stringify(report));
