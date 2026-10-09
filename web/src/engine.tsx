import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { encodeFunctionData, getAddress, type Address, type Hex } from "viem";
import {
  loadConfig,
  walletClient,
  type Contract,
  type Runtime,
  type Provider,
} from "./config";
import { friendlyError, switchChain } from "./logic";
export type Tx = {
  contract: Contract;
  functionName: string;
  args?: any[];
  value?: bigint;
  expiresAt?: number;
  summary: string;
};
export type Snapshot = {
  at: number;
  block: bigint;
  shop: Record<string, any>;
  pool: Record<string, any>;
  burn: Record<string, any>;
  lock: Record<string, any>;
  token: Record<string, any>;
  terms: any[];
  collection: any[];
  floor: any[];
  fresh: boolean;
  debt: bigint;
  poolContract: Contract;
  lockContract: Contract;
  collectionAddress: Address;
};
export async function read(
  r: Runtime,
  c: Contract,
  fn: string,
  args: any[] = [],
): Promise<any> {
  return r.client.readContract({
    address: c.address,
    abi: c.abi,
    functionName: fn,
    args,
  });
}
async function fields(
  r: Runtime,
  c: Contract,
  keys: string[],
  args: any[] = [],
) {
  return Object.fromEntries(
    await Promise.all(keys.map(async (k) => [k, await read(r, c, k, args)])),
  );
}
export async function verifyCode(r: Runtime, addresses: Address[]) {
  if ((await r.client.getChainId()) !== r.deployment.chainId)
    throw Error(
      "The RPC is on the wrong chain. Transaction controls are disabled.",
    );
  await Promise.all(
    addresses.map(async (a) => {
      const code = await r.client.getCode({ address: a });
      if (!code || code === "0x")
        throw Error(
          `No contract code at ${a}. Transaction controls are disabled.`,
        );
    }),
  );
}
export async function fetchSnapshot(
  r: Runtime,
  account?: Address,
): Promise<Snapshot> {
  const shopContract = r.contracts.PawnShop,
    tokenContract = r.contracts.LaunchToken,
    burnContract = r.contracts.MilestoneBurn;
  await verifyCode(
    r,
    Object.values(r.contracts).map((c) => c.address),
  );
  const [shop, burn, token, terms, block] = await Promise.all([
    fields(r, shopContract, [
      "lendingPool",
      "discountModule",
      "vaultFactory",
      "IDENTITY_COLLECTION",
      "owner",
      "pendingOwner",
      "newLoansPaused",
      "nextLoanId",
      "bountyReserve",
      "protocolFeesToRecipient",
      "protocolFeesToReserves",
      "IDENTITY_QUESTION_HASH",
      "oracleSigner",
      "feeRecipient",
      "pawnToken",
    ]),
    fields(r, burnContract, [
      "questionHash",
      "questionSetter",
      "burned",
      "burnedAmount",
      "oracleSigner",
      "pawnToken",
      "pawnShop",
    ]),
    fields(r, tokenContract, ["name", "symbol", "decimals", "totalSupply"]),
    Promise.all([
      read(r, shopContract, "terms", [0n]),
      read(r, shopContract, "terms", [1n]),
    ]),
    r.client.getBlockNumber(),
  ]);
  if (
    shop.pawnToken.toLowerCase() !== tokenContract.address.toLowerCase() ||
    burn.pawnToken.toLowerCase() !== tokenContract.address.toLowerCase() ||
    burn.pawnShop.toLowerCase() !== shopContract.address.toLowerCase()
  )
    throw Error("Deployed contract bindings do not match the handoff.");
  const poolContract = {
      name: "LendingPool",
      address: shop.lendingPool,
      abi: r.abis.LendingPool,
    },
    lockContract = {
      name: "LockDiscount",
      address: shop.discountModule,
      abi: r.abis.LockDiscount,
    };
  await verifyCode(r, [
    poolContract.address,
    lockContract.address,
    shop.vaultFactory,
  ]);
  const factoryShop = await read(
    r,
    {
      name: "VaultFactory",
      address: shop.vaultFactory,
      abi: r.abis.VaultFactory,
    },
    "pawnShop",
  );
  if (factoryShop.toLowerCase() !== shopContract.address.toLowerCase())
    throw Error("Discovered VaultFactory is not bound to PawnShop.");
  const [pool, lock, collection, floor, fresh, debt] = await Promise.all([
    fields(r, poolContract, [
      "totalAssets",
      "idleAssets",
      "depositCap",
      "totalBorrowed",
      "shortfallReserve",
      "unvestedDonations",
      "unvestedRelease",
      "cumulativeLoanFees",
      "cumulativeDonations",
      "cumulativeLoss",
      "expectedAuctionLoss",
      "owner",
      "pendingOwner",
      "pendingCap",
      "pendingCapAt",
      "asset",
      "decimals",
      "pawnShop",
    ]),
    fields(r, lockContract, ["pawnShop", "pawnToken"]),
    read(r, shopContract, "collections", [shop.IDENTITY_COLLECTION]),
    read(r, shopContract, "floors", [shop.IDENTITY_COLLECTION]),
    read(r, shopContract, "floorFresh", [shop.IDENTITY_COLLECTION]),
    read(r, shopContract, "collectionDebt", [shop.IDENTITY_COLLECTION]),
  ]);
  if (
    pool.pawnShop.toLowerCase() !== shopContract.address.toLowerCase() ||
    lock.pawnShop.toLowerCase() !== shopContract.address.toLowerCase() ||
    lock.pawnToken.toLowerCase() !== tokenContract.address.toLowerCase()
  )
    throw Error("Discovered child contract bindings do not match PawnShop.");
  burn.balance = await read(r, tokenContract, "balanceOf", [
    burnContract.address,
  ]);
  if (account) {
    const [poolUser, lockUser, pawnBalance, ethBalance, shopCredit] =
      await Promise.all([
        fields(
          r,
          poolContract,
          ["balanceOf", "maxWithdraw", "maxDeposit", "claimable"],
          [account],
        ),
        fields(
          r,
          lockContract,
          ["locked", "committed", "unlockable", "tierOf"],
          [account],
        ),
        read(r, tokenContract, "balanceOf", [account]),
        r.client.getBalance({ address: account }),
        read(r, shopContract, "claimable", [account]),
      ]);
    Object.assign(pool, poolUser);
    Object.assign(lock, lockUser);
    token.balance = pawnBalance;
    token.ethBalance = ethBalance;
    shop.claimable = shopCredit;
  }
  return {
    at: Date.now(),
    block,
    shop,
    pool,
    burn,
    lock,
    token,
    terms,
    collection,
    floor,
    fresh,
    debt,
    poolContract,
    lockContract,
    collectionAddress: shop.IDENTITY_COLLECTION,
  };
}
type TransactionStatus = {
  label: string;
  phase: string;
  hash?: Hex;
  error?: string;
};
type Engine = {
  transaction?: TransactionStatus;
  runtime?: Runtime;
  snapshot?: Snapshot;
  account?: Address;
  chainId?: number;
  error?: string;
  loading: boolean;
  refresh: () => Promise<void>;
  connect: () => Promise<void>;
  disconnect: () => void;
  switchNetwork: () => Promise<void>;
  walletError?: string;
  walletBusy: boolean;
  ready: boolean;
  pending: boolean;
  send: (tx: Tx, onHash: (hash: Hex) => void) => Promise<void>;
  simulate: (tx: Tx) => Promise<void>;
};
const Context = createContext<Engine>(null!);
export const useEngine = () => useContext(Context);
export function EngineProvider({ children }: { children: ReactNode }) {
  const [runtime, setRuntime] = useState<Runtime>();
  const [snapshot, setSnapshot] = useState<Snapshot>();
  const [account, setAccount] = useState<Address>();
  const [chainId, setChainId] = useState<number>();
  const [error, setError] = useState<string>();
  const [walletError, setWalletError] = useState<string>();
  const [loading, setLoading] = useState(true);
  const [walletBusy, setWalletBusy] = useState(false);
  const [pending, setPending] = useState(false);
  const [transaction, setTransaction] = useState<TransactionStatus>();
  const pendingHash = useRef<Hex | undefined>(undefined);
  const lock = useRef(false);
  const generation = useRef(0);
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    loadConfig()
      .then(setRuntime)
      .catch((e) => {
        setError(friendlyError(e));
        setLoading(false);
      });
    return () => {
      mounted.current = false;
    };
  }, []);
  const refresh = useCallback(async () => {
    if (!runtime) return;
    const g = ++generation.current;
    setLoading(true);
    try {
      const next = await fetchSnapshot(runtime, account);
      if (pendingHash.current) {
        try {
          const receipt = await runtime.client.getTransactionReceipt({
            hash: pendingHash.current,
          });
          if (receipt) {
            setTransaction((t) =>
              t
                ? {
                    ...t,
                    phase:
                      receipt.status === "success" ? "Confirmed" : "Reverted",
                  }
                : t,
            );
            pendingHash.current = undefined;
            lock.current = false;
            setPending(false);
          }
        } catch {
          /* A pending receipt is not an RPC-health failure. */
        }
      }
      if (mounted.current && g === generation.current) {
        setSnapshot(next);
        setError(undefined);
      }
    } catch (e) {
      if (g === generation.current) {
        setError(friendlyError(e));
        setSnapshot(undefined);
      }
    } finally {
      if (g === generation.current) setLoading(false);
    }
  }, [runtime, account]);
  useEffect(() => {
    setSnapshot(undefined);
    void refresh();
    const id = setInterval(() => {
      if (!document.hidden && !lock.current) void refresh();
    }, 30000);
    return () => {
      generation.current++;
      clearInterval(id);
    };
  }, [refresh]);
  useEffect(() => {
    const p = window.ethereum;
    if (!p) return;
    const accounts = (a: Address[]) => {
      setAccount(a[0]);
      setSnapshot(undefined);
    };
    const chain = (c: string) => {
      setChainId(Number(c));
      setSnapshot(undefined);
      void refresh();
    };
    const disconnected = () => {
      setAccount(undefined);
      setChainId(undefined);
    };
    p.on?.("accountsChanged", accounts);
    p.on?.("chainChanged", chain);
    p.on?.("disconnect", disconnected);
    return () => {
      p.removeListener?.("accountsChanged", accounts);
      p.removeListener?.("chainChanged", chain);
      p.removeListener?.("disconnect", disconnected);
    };
  }, [refresh]);
  async function walletTask(fn: (p: Provider) => Promise<void>) {
    setWalletBusy(true);
    setWalletError(undefined);
    try {
      if (!window.ethereum)
        throw Error(
          "No browser wallet found. Open this page in an Ethereum wallet browser or install a browser wallet, then reload.",
        );
      await fn(window.ethereum);
    } catch (e) {
      setWalletError(friendlyError(e));
    } finally {
      setWalletBusy(false);
    }
  }
  const connect = () =>
    walletTask(async (p) => {
      const a = await p.request({ method: "eth_requestAccounts" });
      setAccount(a[0] ? getAddress(a[0]) : undefined);
      setChainId(Number(await p.request({ method: "eth_chainId" })));
    });
  const switchNetwork = () =>
    walletTask(async (p) => {
      if (!runtime) return;
      await switchChain(p, runtime.deployment);
      setChainId(Number(await p.request({ method: "eth_chainId" })));
      await refresh();
    });
  const ready =
    !!runtime &&
    !!snapshot &&
    !!account &&
    chainId === runtime.deployment.chainId &&
    !error;
  async function ensure() {
    if (!ready || !runtime || !account || !window.ethereum)
      throw Error(
        "Connect a wallet on the configured network and refresh contract verification.",
      );
    const [id, accounts] = await Promise.all([
      window.ethereum.request({ method: "eth_chainId" }),
      window.ethereum.request({ method: "eth_accounts" }),
    ]);
    if (
      Number(id) !== runtime.deployment.chainId ||
      accounts[0]?.toLowerCase() !== account.toLowerCase()
    )
      throw Error(
        "Wallet account or network changed. Reconnect and review again.",
      );
    return { r: runtime, a: account, p: window.ethereum };
  }
  async function simulate(tx: Tx) {
    if (tx.expiresAt && Date.now() > tx.expiresAt)
      throw Error("Quote expired. Get a fresh quote and review again.");
    const { r, a } = await ensure();
    await verifyCode(r, [tx.contract.address]);
    await r.client.simulateContract({
      address: tx.contract.address,
      abi: tx.contract.abi,
      functionName: tx.functionName,
      args: tx.args ?? [],
      account: a,
      value: tx.value ?? 0n,
    });
  }
  async function send(tx: Tx, onHash: (hash: Hex) => void) {
    if (lock.current)
      throw Error("Wait for the pending transaction to finish.");
    lock.current = true;
    setPending(true);
    setTransaction({ label: tx.functionName, phase: "Confirm in wallet" });
    try {
      const { r, a, p } = await ensure();
      await simulate(tx);
      const hash = await walletClient(r, p, a).sendTransaction({
        to: tx.contract.address,
        data: encodeFunctionData({
          abi: tx.contract.abi,
          functionName: tx.functionName,
          args: tx.args ?? [],
        }),
        value: tx.value ?? 0n,
      });
      pendingHash.current = hash;
      setTransaction({
        label: tx.functionName,
        phase: "Waiting for confirmation",
        hash,
      });
      onHash(hash);
      let replacementReason: string | undefined;
      let effectiveHash = hash;
      const receipt = await r.client.waitForTransactionReceipt({
        hash,
        confirmations: 1,
        timeout: 180000,
        onReplaced: (replacement) => {
          replacementReason = replacement.reason;
          effectiveHash = replacement.transaction.hash;
          pendingHash.current = effectiveHash;
          onHash(effectiveHash);
          setTransaction({
            label: tx.functionName,
            phase: `Transaction ${replacement.reason}; checking receipt`,
            hash: effectiveHash,
          });
        },
      });
      pendingHash.current = undefined;
      if (replacementReason && replacementReason !== "repriced") {
        await refresh();
        throw Error(
          "Your wallet cancelled or replaced this transaction. The requested action was not confirmed. Check the replacement on the explorer.",
        );
      }
      if (receipt.status !== "success")
        throw Error(
          "The transaction reverted on chain. No action completed; refresh and review again.",
        );
      await refresh();
      setTransaction({
        label: tx.functionName,
        phase: "Confirmed",
        hash: effectiveHash,
      });
    } catch (error) {
      setTransaction((t) => ({
        ...t!,
        label: tx.functionName,
        phase: pendingHash.current
          ? "Confirmation not observed — refresh state to recheck"
          : "Failed",
        error: friendlyError(error),
      }));
      throw error;
    } finally {
      if (!pendingHash.current) {
        lock.current = false;
        setPending(false);
      }
    }
  }
  return (
    <Context.Provider
      value={{
        transaction,
        runtime,
        snapshot,
        account,
        chainId,
        error,
        loading,
        refresh,
        connect,
        disconnect: () => {
          setAccount(undefined);
          setChainId(undefined);
          setWalletError(undefined);
        },
        switchNetwork,
        walletError,
        walletBusy,
        ready,
        pending,
        send,
        simulate,
      }}
    >
      {children}
    </Context.Provider>
  );
}
