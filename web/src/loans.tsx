import { useEffect, useState } from "react";
import { type Address } from "viem";
import { useEngine, read, verifyCode } from "./engine";
import { erc20, type Contract } from "./config";
import { address, amount, uint } from "./logic";
import {
  Action,
  AddressLink,
  Field,
  Notice,
  Pair,
  Panel,
  ReadButton,
  units,
  when,
} from "./components";
import { ContractForm } from "./forms";
import { moduleFee } from "./finance";
type Loan = {
  borrower: Address;
  collection: Address;
  vault: Address;
  module: Address;
  tokenId: bigint;
  principal: bigint;
  due: bigint;
  auctionStarted: bigint;
  auctionFloor: bigint;
  status: number;
  savedTerms: { duration: number; feeBps: number }[];
};
const statuses = ["Missing", "Active", "In auction", "Repaid", "Sold"];
export function Loans() {
  const e = useEngine(),
    s = e.snapshot,
    r = e.runtime;
  const [ids, setIds] = useState<{ id: bigint; loan: Loan }[]>([]),
    [page, setPage] = useState(0),
    [filter, setFilter] = useState("all"),
    [id, setId] = useState(""),
    [selected, setSelected] = useState<{ id: bigint; loan: Loan }>(),
    [error, setError] = useState("");
  async function list() {
    if (!r || !s) return;
    const end = s.shop.nextLoanId - 1n - BigInt(page * 10);
    const next = await Promise.all(
      Array.from(
        { length: Number(end > 10n ? 10n : end > 0n ? end : 0n) },
        async (_, i) => {
          const n = end - BigInt(i);
          return {
            id: n,
            loan: (await read(r, r.contracts.PawnShop, "getLoan", [n])) as Loan,
          };
        },
      ),
    );
    setIds(next);
  }
  useEffect(() => {
    setIds([]);
    void list().catch(() =>
      setError("Could not load loans. Refresh contract state to retry."),
    );
  }, [r, s?.at, page]);
  useEffect(() => {
    if (selected && r)
      read(r, r.contracts.PawnShop, "getLoan", [selected.id])
        .then((loan) => setSelected({ id: selected.id, loan }))
        .catch(() => setSelected(undefined));
  }, [s?.at]);
  const filtered = ids.filter(
    (x) =>
      filter === "all" ||
      (filter === "mine" &&
        x.loan.borrower.toLowerCase() === e.account?.toLowerCase()) ||
      (filter === "auctions" && x.loan.status === 2),
  );
  return (
    <>
      <div className="workspace-grid">
        <Panel kicker="04 / Loans & auctions" title="Every seat has a story.">
          <div className="form-row">
            <Field
              label="Show loans"
              value={filter}
              onChange={setFilter}
              options={[
                { value: "all", label: "All loans" },
                { value: "mine", label: "My loans" },
                { value: "auctions", label: "Auctions" },
              ]}
            />
            <Field
              label="Look up loan ID"
              value={id}
              onChange={setId}
              type="number"
            />
          </div>
          <ReadButton
            label="Load loan"
            run={async () => {
              if (!r) throw Error("Deployment configuration is loading.");
              const n = uint(id),
                loan = (await read(r, r.contracts.PawnShop, "getLoan", [
                  n,
                ])) as Loan;
              if (!loan.status)
                throw Error("No loan exists at this ID. Check the number.");
              setSelected({ id: n, loan });
            }}
          />
          {error && (
            <p className="error" role="alert">
              {error}
            </p>
          )}
          <div className="loan-list">
            {filtered.length ? (
              filtered.map(({ id, loan }) => (
                <button
                  className="loan-row"
                  key={String(id)}
                  onClick={() => setSelected({ id, loan })}
                >
                  <span>
                    <strong>Loan #{String(id)}</strong>
                    <small>Seat #{String(loan.tokenId)}</small>
                  </span>
                  <span>
                    {units(loan.principal)} ETH
                    <small>{statuses[loan.status]} →</small>
                  </span>
                </button>
              ))
            ) : (
              <Notice>
                {s?.shop.nextLoanId === 1n
                  ? "No loans have been opened yet. Borrowing begins once the owner completes setup."
                  : "No matching loans on this page. Change the filter or look up a loan ID."}
              </Notice>
            )}
          </div>
          <div className="button-row">
            <button disabled={page === 0} onClick={() => setPage(page - 1)}>
              Newer loans
            </button>
            <button
              disabled={!s || s.shop.nextLoanId <= BigInt((page + 1) * 10 + 1)}
              onClick={() => setPage(page + 1)}
            >
              Older loans
            </button>
          </div>
          <small>
            Latest 10 per page. “My loans” filters this page; older positions
            remain available by ID.
          </small>
        </Panel>
        <Panel title="Credits & auction rules">
          <Pair label="Claimable shop ETH">{units(s?.shop.claimable)} ETH</Pair>
          <Action
            label="Claim shop ETH"
            disabled={!s?.shop.claimable}
            prepare={() => ({
              contract: r!.contracts.PawnShop,
              functionName: "claim",
              args: [e.account],
              summary: `Claim ${units(s?.shop.claimable)} ETH to your connected wallet. This includes borrowed proceeds, bounties, auction excess or protocol fees credited to you.`,
            })}
          />
          <p>
            Auctions may begin after the due date plus 3 days. The price starts
            at the stored floor, falls to 70% over 72 hours, then to 50% over 7
            days.
          </p>
          <p>
            Repay or extend before the auction starts. Once it starts, these
            options close.
          </p>
          <p>
            Starting an auction can earn a 0.002 ETH bounty if the bounty
            reserve can cover it. Claims are separate transactions.
          </p>
        </Panel>
      </div>
      {selected && (
        <LoanDetails
          key={`${selected.id}-${e.account}`}
          id={selected.id}
          loan={selected.loan}
        />
      )}
    </>
  );
}
function LoanDetails({ id, loan }: { id: bigint; loan: Loan }) {
  const e = useEngine(),
    r = e.runtime,
    s = e.snapshot;
  const [term, setTerm] = useState("0"),
    [data, setData] = useState<{
      holds: boolean;
      total: bigint;
      balance: bigint;
      expires: bigint;
      fresh: boolean;
      written: boolean;
      realised: boolean;
      openedAt: bigint;
      price: bigint;
      credit: bigint;
      isSeat: boolean;
    }>(),
    [error, setError] = useState("");
  const c: Contract | undefined = r
    ? {
        name: `Loan #${id} vault`,
        address: loan.vault,
        abi: r.abis.CollateralVault,
      }
    : undefined;
  async function refresh() {
    if (!r || !c) return;
    setError("");
    try {
      await verifyCode(r, [loan.vault, loan.module]);
      const [borrower, boundId, shop] = await Promise.all([
        read(r, c, "borrower"),
        read(r, c, "loanId"),
        read(r, c, "pawnShop"),
      ]);
      if (
        borrower.toLowerCase() !== loan.borrower.toLowerCase() ||
        boundId !== id ||
        shop.toLowerCase() !== r.contracts.PawnShop.address.toLowerCase()
      )
        throw Error("The vault does not match the selected loan.");
      const [
        holds,
        total,
        balance,
        expires,
        fresh,
        written,
        realised,
        openedAt,
        price,
        credit,
        isSeat,
      ] = await Promise.all([
        read(r, c, "holdsCollateral"),
        read(r, c, "totalClaimable"),
        r.client.getBalance({ address: loan.vault }),
        read(r, c, "workerExpiresAt"),
        read(r, r.contracts.PawnShop, "floorFresh", [loan.collection]),
        read(r, r.contracts.PawnShop, "writtenOff", [id]),
        read(r, r.contracts.PawnShop, "debtRealised", [id]),
        read(r, r.contracts.PawnShop, "auctionOpenedAt", [id]),
        loan.status === 2
          ? read(r, r.contracts.PawnShop, "auctionPrice", [id])
          : Promise.resolve(0n),
        e.account ? read(r, c, "claimable", [e.account]) : Promise.resolve(0n),
        read(r, c, "isSeat"),
      ]);
      setData({
        holds,
        total,
        balance,
        expires,
        fresh,
        written,
        realised,
        openedAt,
        price,
        credit,
        isSeat,
      });
    } catch (x) {
      setData(undefined);
      setError(x instanceof Error ? x.message : "Could not read vault.");
    }
  }
  useEffect(() => {
    setData(undefined);
    void refresh();
  }, [r, s?.at, loan.status, e.account]);
  const mine = e.account?.toLowerCase() === loan.borrower.toLowerCase();
  const active = loan.status === 1;
  const auction = loan.status === 2;
  const now = BigInt(Math.floor(Date.now() / 1000));
  return (
    <div className="workspace-grid loan-details">
      <Panel title={`Loan #${id} · ${statuses[loan.status]}`}>
        <Pair label="Borrower">
          <AddressLink value={loan.borrower} />
        </Pair>
        <Pair label="Collection">
          <AddressLink value={loan.collection} />
        </Pair>
        <Pair label="Seat token ID">{String(loan.tokenId)}</Pair>
        <Pair label="Principal">{units(loan.principal)} ETH</Pair>
        <Pair label="Due">{when(loan.due)}</Pair>
        <Pair label="Auction eligible after">{when(loan.due + 259200n)}</Pair>
        <Pair label="Original discount module">
          <AddressLink value={loan.module} />
        </Pair>
        {error && <Notice tone="warning">{error}</Notice>}
        <Action
          label="Repay loan"
          disabled={!active || !data}
          reason={
            !active ? "Repayment closes when an auction starts." : undefined
          }
          prepare={() => ({
            contract: r!.contracts.PawnShop,
            functionName: "repay",
            args: [id],
            value: loan.principal,
            summary: `Pay ${units(loan.principal)} ETH to repay loan #${id}. Return the seat to the original borrower and release its PAWN commitment.`,
          })}
        />
        <Field
          label="Extension term"
          value={term}
          onChange={setTerm}
          options={loan.savedTerms.map((t, i) => ({
            value: String(i),
            label: `${t.duration / 86400} days · ${t.feeBps / 100}% base fee (saved term)`,
          }))}
        />
        <Action
          key={`${term}-${loan.due}`}
          label="Extend loan"
          disabled={!mine || !active || !data?.fresh}
          reason={
            !data?.fresh
              ? "A fresh floor is required to extend."
              : !mine
                ? "Only the borrower can extend."
                : undefined
          }
          prepare={async () => {
            const module = {
              name: "Original discount module",
              address: loan.module,
              abi: r!.abis.LockDiscount,
            };
            const f = await moduleFee(
              r!,
              module,
              id,
              loan.borrower,
              loan.principal,
              loan.savedTerms[Number(term)].feeBps,
            );
            return {
              contract: r!.contracts.PawnShop,
              functionName: "extend",
              args: [id, Number(term)],
              value: f,
              summary: `Pay ${units(f)} ETH to extend loan #${id} until approximately ${when((loan.due > now ? loan.due : now) + BigInt(loan.savedTerms[Number(term)].duration))}. Your current tier in the original module becomes the new commitment.`,
            };
          }}
        />
        <Action
          label="Start auction"
          disabled={!data || !active || now <= loan.due + 259200n}
          prepare={() => ({
            contract: r!.contracts.PawnShop,
            functionName: "startAuction",
            args: [id],
            summary: `Start the default auction for loan #${id}. This permanently closes repayment and extension. A 0.002 ETH bounty is credited only if reserve funds are available.`,
          })}
        />
        {auction && (
          <>
            <Pair label="Current auction price">{units(data?.price)} ETH</Pair>
            <Pair label="Collateral present">
              {data
                ? data.holds
                  ? "Yes"
                  : "No — collateral unavailable"
                : "Checking…"}
            </Pair>
            <Action
              label="Buy auction seat"
              disabled={!data?.holds}
              prepare={async () => {
                const price = await read(
                  r!,
                  r!.contracts.PawnShop,
                  "auctionPrice",
                  [id],
                );
                return {
                  contract: r!.contracts.PawnShop,
                  functionName: "buyAuction",
                  args: [id, e.account],
                  value: price,
                  summary: `Buy seat #${loan.tokenId} for at most ${units(price)} ETH. Send the NFT to your connected wallet. Any price decrease becomes shop credit.`,
                };
              }}
            />
            <Action
              label="Refresh auction loss"
              disabled={!data || data.realised}
              prepare={() => ({
                contract: r!.contracts.PawnShop,
                functionName: "markAuctionLoss",
                args: [id],
                summary:
                  "Update the pool’s loss allowance to reflect this auction’s current recovery ceiling.",
              })}
            />
            <Action
              label="Write off auction debt"
              disabled={
                !data ||
                data.realised ||
                (data.holds &&
                  (data.written || now < data.openedAt + 3456000n))
              }
              reason="Available 40 days after the auction first opened, or earlier if collateral is missing. The auction remains open; held collateral stays an expected-loss allowance until it is sold or gone."
              prepare={() => ({
                contract: r!.contracts.PawnShop,
                functionName: "writeOffAuction",
                args: [id],
                summary: `Recognize the unrecovered principal on loan #${id} as a loss, release its PAWN commitment, and leave the seat in auction.`,
              })}
            />
          </>
        )}
      </Panel>
      <Panel title="The working seat vault">
        <AddressLink value={loan.vault} label="Collateral vault" />
        <Pair label="Worker authorization expires">{when(data?.expires)}</Pair>
        <Pair label="Free vault ETH">
          {data ? units(data.balance - data.total) : "—"} ETH
        </Pair>
        <Pair label="Your vault credit">{units(data?.credit)} ETH</Pair>
        {!mine && (
          <Notice>Only the original borrower can manage this vault.</Notice>
        )}
        {c && (
          <>
            <ContractForm
              contract={c}
              fn="authorizeWorker"
              label="Authorize worker device"
              description="Register the IMD pairing message for this seat. Paste its message object (or the full object with a message field). Check wallet is this vault, tokenId matches this seat, and expiry is in the future."
              disabled={!mine || !active || !data?.holds || !data?.isSeat}
            />
            <Action
              label="Revoke worker device"
              disabled={!mine || !data}
              prepare={() => ({
                contract: c,
                functionName: "revokeWorker",
                summary: "Revoke the current worker authorization immediately.",
              })}
            />
            <ContractForm
              contract={c}
              fn="callFor"
              label="Claim rewards through vault"
              description="Call the reward contract from your vault, with no ETH. Enter its target and encoded call data. Collection, PawnShop, LendingPool and vault targets are forbidden; this call cannot remove the seat."
              disabled={!mine || !active || !data?.holds}
            />
            <Action
              label="Move free vault ETH to credit"
              disabled={!mine || !data || data.balance <= data.total}
              prepare={() => ({
                contract: c,
                functionName: "withdrawETH",
                args: [data!.balance - data!.total],
                summary: `Move ${units(data!.balance - data!.total)} ETH to your vault credit. Claim it separately below.`,
              })}
            />
            <Action
              label="Claim vault ETH"
              disabled={!data?.credit}
              prepare={() => ({
                contract: c,
                functionName: "claim",
                args: [e.account],
                summary: `Send ${units(data?.credit)} ETH of your vault credit to your connected wallet.`,
              })}
            />
            <VaultToken
              contract={c}
              disabled={!mine || !data}
              collection={loan.collection}
            />
          </>
        )}
      </Panel>
    </div>
  );
}
function VaultToken({
  contract,
  disabled,
  collection,
}: {
  contract: Contract;
  disabled: boolean;
  collection: Address;
}) {
  const e = useEngine();
  const [token, setToken] = useState(""),
    [v, setV] = useState(""),
    [info, setInfo] = useState<{
      address: Address;
      symbol: string;
      decimals: number;
      balance: bigint;
    }>();
  return (
    <details className="contract-form">
      <summary>Withdraw vault tokens</summary>
      <Field
        label="ERC-20 token address"
        value={token}
        onChange={(x) => {
          setToken(x);
          setInfo(undefined);
        }}
      />
      <ReadButton
        label="Read vault token balance"
        run={async () => {
          if (!e.runtime) throw Error("Wait for configuration.");
          const a = address(token);
          if (a.toLowerCase() === collection.toLowerCase())
            throw Error(
              "The collateral collection cannot be withdrawn as a token.",
            );
          const c = { name: "Vault token", address: a, abi: erc20 };
          const [symbol, decimals, balance] = await Promise.all([
            read(e.runtime, c, "symbol"),
            read(e.runtime, c, "decimals"),
            read(e.runtime, c, "balanceOf", [contract.address]),
          ]);
          setInfo({ address: a, symbol, decimals, balance });
        }}
      />
      {info && (
        <>
          <Pair label="Vault balance">
            {units(info.balance, info.decimals)} {info.symbol}
          </Pair>
          <Field
            label={`Amount (${info.symbol})`}
            value={v}
            onChange={setV}
            type="number"
          />
          <Action
            key={token + v}
            label="Withdraw vault tokens"
            disabled={disabled}
            prepare={() => {
              const n = amount(v, info.decimals);
              if (n > info.balance)
                throw Error("Amount exceeds the vault token balance.");
              return {
                contract,
                functionName: "withdrawToken",
                args: [info.address, n],
                summary: `Send ${units(n, info.decimals)} ${info.symbol} from the vault to its original borrower.`,
              };
            }}
          />
        </>
      )}
    </details>
  );
}
