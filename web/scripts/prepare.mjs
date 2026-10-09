import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { root, web, handoff, abiHash, header, files, sha } from "./common.mjs";
mkdirSync(resolve(web, "public/abi"), { recursive: true });
for (const name of [
  "LaunchToken",
  "PawnShop",
  "MilestoneBurn",
  "LendingPool",
  "LockDiscount",
  "CollateralVault",
  "FloorRelay",
  "VaultFactory",
]) {
  const path = `docs/abi/${name}.json`;
  const pinned = execFileSync(
    "git",
    ["show", `${handoff.sourceCommit}:${path}`],
    { cwd: root },
  );
  if (!pinned.equals(readFileSync(resolve(root, path))))
    throw Error(`ABI differs from pinned source: ${name}`);
  const abi = JSON.parse(pinned);
  if (!Array.isArray(abi)) throw Error("ABI must be an array");
  const match = handoff.contracts.find((c) => c.name === name);
  const hash = abiHash(abi);
  if (match && hash !== match.abiHash)
    throw Error(`ABI hash mismatch: ${name}: ${hash}`);
  writeFileSync(resolve(web, "public/abi", name + ".json"), pinned);
  console.log(
    `${name}: ${hash} ${match ? "handoff verified" : "pinned-source verified"}`,
  );
}
// Development config; production inventory is always regenerated after Vite.
writeFileSync(
  resolve(web, "public/imd-deployment.json"),
  JSON.stringify(
    {
      ...header(),
      assets: files(resolve(web, "public"))
        .filter((path) => path !== "imd-deployment.json")
        .map((path) => ({
          path,
          sha256: sha(readFileSync(resolve(web, "public", path))),
        })),
    },
    null,
    2,
  ) + "\n",
);
