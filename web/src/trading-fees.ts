import {
  parseAbi,
  decodeAbiParameters,
  parseAbiParameters,
  type Address,
} from "viem";
import handoff from "../deployment.json";
import { type Runtime, type Contract } from "./config";
export const factoryABI = parseAbi([
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "function positionOf(uint64) view returns (PoolKey poolKey,int24 tickLower,int24 tickUpper,address recipient)",
  "function claimFees(uint64) returns (uint256 amount0,uint256 amount1)",
]);
export async function tradingFees(r: Runtime, account: Address) {
  // Trading liquidity and fees belong to the unchanged token’s original launch.
  const record = handoff.contracts.find((c) => c.name === "LaunchToken")!;
  const receipt = await r.client.getTransactionReceipt({
    hash: record.txHash as `0x${string}`,
  });
  if (
    receipt.status !== "success" ||
    receipt.blockNumber !== BigInt(record.blockNumber) ||
    !receipt.to ||
    !receipt.logs.some(
      (l) =>
        l.address.toLowerCase() ===
        r.contracts.LaunchToken.address.toLowerCase(),
    )
  )
    throw Error("Launch receipt provenance could not be verified.");
  const launchLog = receipt.logs.find(
    (l) =>
      l.address.toLowerCase() === receipt.to!.toLowerCase() &&
      l.topics[2]?.toLowerCase() ===
        (
          "0x" +
          "0".repeat(24) +
          r.contracts.LaunchToken.address.slice(2)
        ).toLowerCase(),
  );
  if (!launchLog) throw Error("Project launch event unavailable.");
  const [distributor, children] = decodeAbiParameters(
    parseAbiParameters("address,address[]"),
    launchLog.data,
  );
  if (
    !children.some(
      (a) =>
        a.toLowerCase() ===
        handoff.tokenLaunch.contracts
          .find((c) => c.name === "PawnShop")!
          .address.toLowerCase(),
    ) ||
    !children.some(
      (a) =>
        a.toLowerCase() ===
        handoff.tokenLaunch.contracts
          .find((c) => c.name === "MilestoneBurn")!
          .address.toLowerCase(),
    )
  )
    throw Error("Project launch bindings mismatch.");
  const distributorCode = await r.client.getCode({ address: distributor });
  if (!distributorCode || distributorCode === "0x")
    throw Error("Distributor code unavailable.");
  const factory: Contract = {
    name: "Launch factory",
    address: receipt.to,
    abi: factoryABI,
  };
  const code = await r.client.getCode({ address: factory.address });
  if (!code || code === "0x") throw Error("Launch factory code unavailable.");
  // The launch number is verified by the position's exact pool key and the launch receipt.
  const launchNumber = BigInt(launchLog.topics[1]!);
  if (launchNumber !== 994n) throw Error("Launch number mismatch.");
  const [key, , , recipient] = await r.client.readContract({
    address: factory.address,
    abi: factoryABI,
    functionName: "positionOf",
    args: [launchNumber],
  });
  const expected = r.deployment.poolKey;
  if (
    key.currency0.toLowerCase() !== expected.currency0.toLowerCase() ||
    key.currency1.toLowerCase() !== expected.currency1.toLowerCase() ||
    key.hooks.toLowerCase() !== expected.hooks.toLowerCase() ||
    key.fee !== expected.fee ||
    key.tickSpacing !== expected.tickSpacing
  )
    throw Error("Factory position does not match the attested PAWN pool.");
  const simulation = await r.client.simulateContract({
    address: factory.address,
    abi: factoryABI,
    functionName: "claimFees",
    args: [launchNumber],
    account,
  });
  return {
    factory,
    distributor,
    launchNumber,
    recipient,
    amounts: simulation.result,
  };
}
