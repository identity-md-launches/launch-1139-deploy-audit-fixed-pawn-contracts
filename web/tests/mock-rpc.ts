// Deterministic RPC and wallet fixtures. Never used or bundled by the application.
import { readFileSync } from "node:fs";
import {
  decodeFunctionData,
  encodeFunctionResult,
  encodeErrorResult,
  parseEther,
  zeroAddress,
  type Abi,
} from "viem";
import {
  erc20,
  erc721,
  permit2,
  router,
  quoter,
  stateView,
} from "../src/config";
const json = (p: string) =>
  JSON.parse(readFileSync(new URL(p, import.meta.url), "utf8"));
export const manifest = json("../../dist/imd-deployment.json");
const live = json("../../docs/frontend/live-read.json");
export const addresses = Object.fromEntries(
  manifest.contracts.map((c: any) => [c.name, c.address.toLowerCase()]),
);
export const owner = live.state.owner;
export const collection = live.state.collection;
const now = Math.floor(Date.now() / 1000);
const hash = "0x" + "ab".repeat(32);
export class World {
  calls: any[] = [];
  sends: any[] = [];
  allowances = new Map<string, bigint>();
  permit = 0n;
  permitExpiry = 0;
  approved = false;
  paused = false;
  noCode = false;
  revertOn = "";
  receiptDelay = 0;
  sentAt = 0;
  locked = parseEther("1000000");
  burned = false;
  loanStatus = new Map([
    [1, 1],
    [2, 1],
    [3, 2],
  ]);
  block = 26146624;
  credit = parseEther(".3");
  cap = parseEther("10");
  pendingCap = 0n;
  floorHash = "0x" + "12".repeat(32);
  abi(to: string): Abi {
    to = to.toLowerCase();
    const name = Object.keys(addresses).find((k) => addresses[k] === to);
    if (name) return json(`../../docs/abi/${name}.json`);
    if (to === collection.toLowerCase()) return erc721;
    for (const [name, abi] of Object.entries({
      permit2,
      universalRouter: router,
      quoter,
      stateView,
    })) {
      if (to === manifest.network.uniswapV4[name]?.toLowerCase()) return abi;
    }
    if (to === this.vault(1) || to === this.vault(2) || to === this.vault(3))
      return json("../../docs/abi/CollateralVault.json");
    return erc20;
  }
  vault(id: number) {
    return `0x${(1000 + id).toString(16).padStart(40, "0")}`;
  }
  loan(id: number) {
    return {
      borrower: owner,
      collection,
      vault: this.vault(id),
      module: addresses.LockDiscount,
      tokenId: BigInt(6 + id),
      principal: parseEther(".4"),
      due: BigInt(now + (id === 2 ? -400000 : 86400)),
      auctionStarted: BigInt(id === 3 ? now - 90000 : 0),
      auctionFloor: parseEther("1"),
      status: this.loanStatus.get(id) ?? 0,
      savedTerms: [
        { duration: 2592000, feeBps: 300 },
        { duration: 604800, feeBps: 100 },
      ],
    };
  }
  decode(tx: any) {
    const abi = this.abi(tx.to);
    const decoded = decodeFunctionData({ abi, data: tx.data });
    return {
      abi,
      fn: decoded.functionName,
      args: decoded.args ?? [],
      to: tx.to.toLowerCase(),
    };
  }
  send(tx: any) {
    const call = this.decode(tx);
    this.sends.push({ ...call, value: BigInt(tx.value ?? 0) });
    this.sentAt = Date.now();
    this.block++;
    const { fn, args, to } = call as any;
    if (fn === "approve") {
      if (to === collection.toLowerCase()) this.approved = true;
      else if (to === manifest.network.uniswapV4.permit2.toLowerCase()) {
        this.permit = args[2];
        this.permitExpiry = args[3];
      } else this.allowances.set(to + args[0].toLowerCase(), args[1]);
    }
    if (fn === "lock") this.locked += args[0];
    if (fn === "unlock") this.locked -= args[0];
    if (fn === "repay") this.loanStatus.set(Number(args[0]), 3);
    if (fn === "startAuction") this.loanStatus.set(Number(args[0]), 2);
    if (fn === "buyAuction") this.loanStatus.set(Number(args[0]), 4);
    if (fn === "claim") this.credit = 0n;
    if (fn === "burn") this.burned = true;
    if (fn === "setNewLoansPaused") this.paused = args[0];
    if (fn === "queueDepositCap") this.pendingCap = args[0];
    return hash;
  }
  callValue(to: string, fn: string, args: any[]): any {
    const isPool = to === addresses.LendingPool,
      isToken = to === addresses.LaunchToken,
      isBurn = to === addresses.MilestoneBurn,
      isVault = to.startsWith("0x00000000000000000000000000000000000003");
    if (fn === "pawnShop") return addresses.PawnShop;
    if (fn === "pawnToken") return addresses.LaunchToken;
    if (fn === "lendingPool") return addresses.LendingPool;
    if (fn === "discountModule") return addresses.LockDiscount;
    if (fn === "vaultFactory") return addresses.VaultFactory;
    if (fn === "IDENTITY_QUESTION_HASH") return this.floorHash;
    if (fn === "approvedQuestionHash") return "0x" + "00".repeat(32);
    if (
      [
        "protocolFeesToRecipient",
        "protocolFeesToReserves",
        "unvestedRelease",
      ].includes(fn)
    )
      return 0n;
    if (fn === "IDENTITY_COLLECTION" || fn === "collection") return collection;
    if (
      fn === "owner" ||
      fn === "questionSetter" ||
      fn === "borrower" ||
      fn === "feeRecipient" ||
      fn === "ownerOf"
    )
      return owner;
    if (fn === "pendingOwner") return zeroAddress;
    if (fn === "oracleSigner") return live.state.oracleSigner;
    if (fn === "newLoansPaused") return this.paused;
    if (fn === "nextLoanId") return 4n;
    if (fn === "getLoan") return this.loan(Number(args[0]));
    if (fn === "loanId") return BigInt(parseInt(to, 16) - 1000);
    if (fn === "terms") return args[0] === 0n ? [2592000, 300] : [604800, 100];
    if (fn === "collections")
      return [4000, 4000, 10000, true, true, this.floorHash];
    if (fn === "floors")
      return [
        parseEther("1"),
        BigInt(now - 1800),
        BigInt(now + 93600),
        BigInt(now - 1800),
      ];
    if (fn === "floorFresh" || fn === "holdsCollateral" || fn === "isSeat")
      return true;
    if (fn === "questionHash") return this.floorHash;
    if (fn === "burned") return this.burned;
    if (fn === "burnedAmount") return this.burned ? parseEther("1000") : 0n;
    if (fn === "writtenOff") return false;
    if (fn === "workerExpiresAt") return BigInt(now + 86400);
    if (fn === "name") return isToken ? "Pawn" : "Pawn Lending Share";
    if (fn === "symbol") return isToken ? "PAWN" : "pETH";
    if (fn === "decimals") return isPool ? 24 : 18;
    if (fn === "totalSupply") return parseEther("1000000000");
    if (fn === "balanceOf") return isPool ? 10n ** 24n : parseEther("50000000");
    if (fn === "asset") return "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
    if (fn === "totalAssets") return parseEther("5");
    if (fn === "idleAssets") return parseEther("3.8");
    if (fn === "totalBorrowed") return parseEther("1.2");
    if (fn === "depositCap") return this.cap;
    if (fn === "pendingCap") return this.pendingCap;
    if (fn === "pendingCapAt") return this.pendingCap ? BigInt(now - 100) : 0n;
    if (fn === "cumulativeLoanFees") return parseEther(".038");
    if (fn === "cumulativeDonations") return parseEther(".1");
    if (fn === "shortfallReserve") return parseEther(".12");
    if (fn === "unvestedDonations") return parseEther(".05");
    if (
      fn === "expectedAuctionLoss" ||
      fn === "cumulativeLoss" ||
      fn === "totalClaimable"
    )
      return 0n;
    if (fn === "bountyReserve") return parseEther(".1");
    if (fn === "collectionDebt") return parseEther("1.2");
    if (fn === "claimable") return this.credit;
    if (fn === "maxWithdraw") return parseEther("1");
    if (fn === "maxDeposit") return parseEther("5");
    if (fn === "maxRedeem") return 10n ** 24n;
    if (fn === "locked") return this.locked;
    if (fn === "committed") return parseEther("1000000");
    if (fn === "unlockable") return this.locked - parseEther("1000000");
    if (fn === "tierOf") return 1;
    if (fn === "commit") return (args[2] * 8000n + 9999n) / 10000n;
    if (fn === "previewDeposit" || fn === "previewWithdraw")
      return args[0] * 1000000n;
    if (fn === "previewRedeem") return args[0] / 1000000n;
    if (fn === "getApproved")
      return this.approved ? addresses.PawnShop : zeroAddress;
    if (fn === "isApprovedForAll") return false;
    if (fn === "allowance") {
      if (to === manifest.network.uniswapV4.permit2.toLowerCase())
        return [this.permit, this.permitExpiry, 0];
      return this.allowances.get(to + args[1].toLowerCase()) ?? 0n;
    }
    if (fn === "getSlot0") return [1000n * (1n << 96n), 0, 0, 12500];
    if (fn === "getLiquidity") return 1000000000000000000000n;
    if (fn === "quoteExactInputSingle")
      return [
        args[0].zeroForOne
          ? args[0].exactAmount * 990000n
          : args[0].exactAmount / 1010101n,
        100000n,
      ];
    if (fn === "auctionPrice") return parseEther(".7");
    if (fn === "queuedAt") return BigInt(now - 100);
    if (fn === "approve" || fn === "transfer" || fn === "transferFrom")
      return true;
    if (fn === "pawn") return 4n;
    if (fn === "depositETH") return parseEther("1") * 1000000n;
    if (fn === "withdrawETH" && !isVault) return 10n ** 24n;
    if (fn === "claim") return this.credit;
    if (fn === "callFor") return "0x";
    return undefined;
  }
  async rpc(payload: any): Promise<any> {
    if (Array.isArray(payload))
      return Promise.all(payload.map((p) => this.rpc(p)));
    const { id, method, params = [] } = payload;
    this.calls.push({ method, params });
    let result: any;
    try {
      if (method === "eth_getTransactionReceipt" && this.receiptDelay)
        await new Promise((resolve) =>
          setTimeout(
            resolve,
            Math.max(0, this.receiptDelay - (Date.now() - this.sentAt)),
          ),
        );
      if (method === "eth_chainId") result = "0x1";
      else if (method === "eth_getLogs") result = [];
      else if (method === "eth_blockNumber")
        result = "0x" + this.block.toString(16);
      else if (method === "eth_getCode")
        result =
          this.noCode ||
          params[0].toLowerCase() === live.state.oracleSigner.toLowerCase()
            ? "0x"
            : "0x60016000";
      else if (method === "eth_getBalance")
        result = "0x" + parseEther("20").toString(16);
      else if (method === "eth_getTransactionReceipt")
        result = {
          transactionHash: hash,
          transactionIndex: "0x0",
          blockHash: "0x" + "cd".repeat(32),
          blockNumber: "0x" + this.block.toString(16),
          from: owner,
          to: addresses.PawnShop,
          cumulativeGasUsed: "0x5208",
          gasUsed: "0x5208",
          contractAddress: null,
          logs: [],
          logsBloom: "0x" + "00".repeat(256),
          status: "0x1",
          effectiveGasPrice: "0x1",
          type: "0x2",
        };
      else if (method === "eth_call") {
        const { abi, fn, args, to } = this.decode(params[0]);
        if (fn === this.revertOn)
          return {
            jsonrpc: "2.0",
            id,
            error: {
              code: 3,
              message: "execution reverted",
              data: encodeErrorResult({
                abi: json("../../docs/abi/LendingPool.json"),
                errorName: "CapExceeded",
              }),
            },
          };
        const value = this.callValue(to, fn, args as any[]);
        result = encodeFunctionResult({ abi, functionName: fn, result: value });
      } else throw Error("Unhandled mock RPC " + method);
      return { jsonrpc: "2.0", id, result };
    } catch (e: any) {
      return {
        jsonrpc: "2.0",
        id,
        error: { code: -32000, message: e.message },
      };
    }
  }
}
export async function mockWallet(
  page: any,
  world: World,
  { chain = "0x1", missing = false, account = owner } = {},
) {
  if (missing) return;
  await page.exposeFunction("__mockSend", (tx: any) => world.send(tx));
  await page.addInitScript(
    ({ owner, chain }: any) => {
      const handlers: Record<string, Function> = {};
      const w = window as any;
      w.walletControl = {
        chain,
        unknown: false,
        reject: false,
        delay: 0,
        calls: [],
      };
      w.ethereum = {
        on: (name: string, fn: Function) => (handlers[name] = fn),
        removeListener: () => {},
        request: async ({ method, params }: any) => {
          w.walletControl.calls.push({ method, params });
          if (
            w.walletControl.reject &&
            (method === "eth_requestAccounts" ||
              method === "eth_sendTransaction")
          )
            throw { code: 4001, message: "User rejected" };
          if (method === "eth_requestAccounts" || method === "eth_accounts")
            return [owner];
          if (method === "eth_chainId") return w.walletControl.chain;
          if (method === "wallet_switchEthereumChain") {
            if (w.walletControl.unknown) {
              w.walletControl.unknown = false;
              throw { code: 4902, message: "Unknown chain" };
            }
            w.walletControl.chain = params[0].chainId;
            handlers.chainChanged?.(params[0].chainId);
            return null;
          }
          if (method === "wallet_addEthereumChain") return null;
          if (method === "eth_sendTransaction") {
            if (w.walletControl.delay)
              await new Promise((resolve) =>
                setTimeout(resolve, w.walletControl.delay),
              );
            return w.__mockSend(params[0]);
          }
          throw Error("Unhandled wallet method " + method);
        },
      };
      w.emitWallet = (event: string, value: any) => handlers[event]?.(value);
    },
    { owner: account, chain },
  );
}
