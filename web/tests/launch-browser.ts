import { createServer } from "node:http";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, extname } from "node:path";
import { chromium, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";
import { privateKeyToAccount } from "viem/accounts";
import { encodeAbiParameters, parseAbiParameters } from "viem";
import { World, mockWallet, addresses, owner, collection } from "./mock-rpc";
import {
  oracleTypes,
  question,
  zeroHash,
  BURN_MILESTONE,
  type Kind,
} from "../src/oracle";

const root = resolve(import.meta.dirname, "../.."),
  out = resolve(root, "docs/frontend/relaunch");
mkdirSync(out, { recursive: true });
const server = createServer((req, res) => {
  try {
    const path = decodeURIComponent((req.url ?? "").split("?")[0]);
    if (!path.startsWith("/preview/") || path.includes(".."))
      throw Error("Not found");
    const file = resolve(root, "dist", path.slice(9) || "index.html");
    res.setHeader(
      "Content-Type",
      (
        {
          ".html": "text/html",
          ".js": "application/javascript",
          ".json": "application/json",
          ".css": "text/css",
          ".svg": "image/svg+xml",
          ".ttf": "font/ttf",
        } as any
      )[extname(file)] ?? "application/octet-stream",
    );
    res.end(readFileSync(file));
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
const url = `http://127.0.0.1:${(server.address() as any).port}/preview/`;
const browser = await chromium.launch({
  headless: true,
  args: ["--no-sandbox"],
});
const report: any = {
  checkedAt: new Date().toISOString(),
  browser: browser.version(),
  mode: "Production dist at /preview/; deterministic RPC and wallet fixtures; signed test attestations; no mainnet transactions",
  checks: [],
  consoleErrors: [],
  failedResources: [],
  viewports: [],
  accessibility: [],
  contrasts: [],
};
const signer = privateKeyToAccount(`0x${"11".repeat(32)}`); // Public fixture key, not an operational wallet.
const other = "0x1111111111111111111111111111111111111111";
const id = "62702d2a-1a38-4543-93cc-7ece5ac20a66";
const hash = `0x${"aa".repeat(32)}`;
const json = (x: any) =>
  JSON.parse(
    JSON.stringify(x, (_, v) => (typeof v === "bigint" ? String(v) : v)),
  );

async function setup(opts: any = {}) {
  const context = await browser.newContext({
    viewport: { width: 1440, height: 1050 },
  });
  const page = await context.newPage(),
    world = new World();
  world.block = 26156401;
  let timestamp = Math.floor(Date.now() / 1000),
    approved = opts.approved ?? zeroHash,
    burnHash = opts.burnHash ?? zeroHash,
    stored = 0n;
  let ev: any;
  const read = world.callValue.bind(world),
    send = world.send.bind(world),
    rpc = world.rpc.bind(world);
  world.callValue = (to, fn, args) => {
    if (fn === "oracleSigner") return signer.address;
    if (fn === "approvedQuestionHash") return approved;
    if (fn === "questionHash") return burnHash;
    if (fn === "questionSetter") return opts.setter ?? owner;
    if (fn === "floors")
      return [
        stored ? 2n * 10n ** 18n : 0n,
        stored,
        BigInt(timestamp + 86400),
        0n,
      ];
    return read(to, fn, args);
  };
  world.send = (tx) => {
    const d = world.decode(tx),
      args: any = d.args;
    if (d.fn === "approveQuestionHash") approved = args[1];
    if (["setQuestionHashOnce", "replaceQuestionHash"].includes(d.fn))
      burnHash = args[0];
    if (d.fn === "submitFloor") stored = args[1].issuedAt;
    return send(tx);
  };
  world.rpc = async (payload) => {
    if (Array.isArray(payload))
      return Promise.all(payload.map((p) => world.rpc(p)));
    if (
      payload.method === "eth_getCode" &&
      payload.params[0].toLowerCase() === signer.address.toLowerCase()
    )
      return { jsonrpc: "2.0", id: payload.id, result: "0x" };
    if (payload.method === "eth_getBlockByNumber")
      return {
        jsonrpc: "2.0",
        id: payload.id,
        result: {
          number: "0x" + world.block.toString(16),
          timestamp: "0x" + timestamp.toString(16),
          hash: "0x" + "bb".repeat(32),
          parentHash: "0x" + "cc".repeat(32),
          transactions: [],
          gasLimit: "0x1c9c380",
          gasUsed: "0x0",
          difficulty: "0x0",
          totalDifficulty: "0x0",
          size: "0x1",
          extraData: "0x",
          nonce: "0x0000000000000000",
          miner: owner,
          baseFeePerGas: "0x1",
        },
      };
    return rpc(payload);
  };
  async function answer(
    kind: Kind,
    value = kind === "floor" ? 2n * 10n ** 18n : BURN_MILESTONE,
    age = 0,
    lifetime = 86400,
  ) {
    const message = {
      requestId: `0x${id.replaceAll("-", "")}${"0".repeat(32)}`,
      chainId: 1n,
      questionHash: hash,
      answerType: 3,
      answer: encodeAbiParameters(parseAbiParameters("uint256"), [value]),
      figure: 0n,
      fromBlock: BigInt(world.block - 20),
      toBlock: BigInt(world.block - 1),
      blockHash: `0x${"bb".repeat(32)}`,
      panelJobId: `0x${"cc".repeat(32)}`,
      panelSize: 5,
      quorum: 4,
      agreed: 4,
      issuedAt: BigInt(timestamp - age),
      expiresAt: BigInt(timestamp - age + lifetime),
    };
    const domain = {
      name: "IdentityMD Oracle",
      version: "2",
      chainId: 1,
      verifyingContract:
        addresses[kind === "floor" ? "PawnShop" : "MilestoneBurn"],
    };
    ev = {
      detail: {
        status: "attested",
        question: question(kind),
        questionHash: hash,
        chainId: 1,
        answerType: "uint256",
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
    return ev;
  }
  await page.addInitScript("window.__name = (fn) => fn;");
  page.on("pageerror", (e) => report.consoleErrors.push(e.message));
  page.on("requestfailed", (r) =>
    report.failedResources.push({
      url: r.url(),
      error: r.failure()?.errorText,
    }),
  );
  await page.route(
    /https:\/\/(ethereum-rpc.publicnode.com|eth.drpc.org)\/?$/,
    async (route) => {
      if (route.request().method() === "OPTIONS")
        return route.fulfill({
          status: 204,
          headers: {
            "access-control-allow-origin": "*",
            "access-control-allow-methods": "POST",
            "access-control-allow-headers": "content-type",
          },
        });
      return route.fulfill({
        json: await world.rpc(route.request().postDataJSON()),
        headers: { "access-control-allow-origin": "*" },
      });
    },
  );
  await page.route("https://api.imd.fun/**", async (route) => {
    expect(route.request().method()).toBe("GET");
    expect(route.request().url()).toContain(`/oracle/requests/${id}`);
    return route.fulfill({
      json: json(
        route.request().url().endsWith("/attestation") ? ev.typed : ev.detail,
      ),
      headers: { "access-control-allow-origin": "*" },
    });
  });
  await mockWallet(page, world, { account: opts.account ?? owner });
  await page.goto(url);
  await expect(page.getByText(/Contract reads verified/)).toBeVisible({
    timeout: 20000,
  });
  if (!opts.disconnected) {
    await page
      .getByRole("button", { name: "Connect wallet", exact: true })
      .click();
    await expect(
      page.getByRole("button", { name: "Disconnect", exact: true }),
    ).toBeVisible();
    await expect(page.getByText(/Contract reads verified/)).toBeVisible();
  }
  await page.goto(url + (opts.route ?? "#setup"));
  return {
    page,
    world,
    context,
    answer,
    setApproved: (v: string) => (approved = v),
    tick: (n: number) => (timestamp += n),
  };
}
async function fetchAnswer(t: any, kind: Kind, publicFlow = false) {
  const flow = t.page.getByRole("region", {
    name: kind === "floor" ? "Refresh floor" : "Market cap request",
    exact: true,
  });
  await flow
    .getByLabel(kind === "floor" ? "Floor request id" : "Market cap request id")
    .fill(id);
  await flow
    .getByRole("button", {
      name:
        kind === "cap"
          ? "Verify market cap"
          : publicFlow
            ? "Refresh floor"
            : "Fetch floor attestation",
      exact: true,
    })
    .click();
  return flow;
}
async function transaction(flow: any, label: string) {
  await flow.getByRole("button", { name: label, exact: true }).click();
  await expect(flow.getByText("Review transaction")).toBeVisible();
  await flow
    .getByRole("button", {
      name: `Confirm ${label.toLowerCase()}`,
      exact: true,
    })
    .click();
}
async function check(name: string, run: () => Promise<void>) {
  await run();
  report.checks.push({ name, result: "passed" });
  console.log("PASS", name);
}
try {
  await check(
    "Setup lists the new deployments; owner explicitly approves a floor hash then posts with no automatic transaction",
    async () => {
      const t = await setup();
      for (const name of [
        "PawnShop",
        "LendingPool",
        "LockDiscount",
        "VaultFactory",
        "FloorRelay",
        "MilestoneBurn",
      ])
        await expect(t.page.locator(".setup-contracts")).toContainText(
          new RegExp(addresses[name], "i"),
        );
      await t.answer("floor");
      const flow = await fetchAnswer(t, "floor");
      await expect(
        flow.getByRole("button", { name: "Approve this hash", exact: true }),
      ).toBeVisible();
      await expect(
        flow.getByRole("button", { name: "Post floor", exact: true }),
      ).toHaveCount(0);
      expect(t.world.sends).toHaveLength(0);
      await transaction(flow, "Approve this hash");
      await expect(
        flow.getByRole("button", { name: "Post floor", exact: true }),
      ).toBeEnabled({ timeout: 15000 });
      expect(t.world.sends.map((x) => x.fn)).toEqual(["approveQuestionHash"]);
      expect(t.world.sends[0].args).toEqual([collection, hash]);
      await transaction(flow, "Post floor");
      await expect(
        flow.getByText("This floor or a newer one is already stored."),
      ).toBeVisible({ timeout: 15000 });
      expect(t.world.sends.map((x) => x.fn)).toEqual([
        "approveQuestionHash",
        "submitFloor",
      ]);
      await t.context.close();
    },
  );
  await check(
    "Disconnected visitor can fetch a floor and sees its hash while waiting for owner approval",
    async () => {
      const t = await setup({ disconnected: true, route: "#borrow" });
      await t.answer("floor");
      const flow = await fetchAnswer(t, "floor", true);
      await expect(flow.getByText(/Waiting for owner approval/)).toBeVisible();
      await expect(flow).toContainText(hash);
      await expect(
        flow.getByRole("button", { name: "Approve this hash", exact: true }),
      ).toHaveCount(0);
      await expect(
        flow.getByRole("button", { name: "Post floor", exact: true }),
      ).toHaveCount(0);
      expect(t.world.sends).toHaveLength(0);
      await t.context.close();
    },
  );
  await check(
    "An approved floor skips approval; owner approval revoked before review prevents posting",
    async () => {
      const t = await setup({ approved: hash, route: "#borrow" });
      await t.answer("floor");
      const flow = await fetchAnswer(t, "floor", true);
      await expect(
        flow.getByRole("button", { name: "Post floor", exact: true }),
      ).toBeEnabled();
      await expect(
        flow.getByRole("button", { name: "Approve this hash", exact: true }),
      ).toHaveCount(0);
      t.setApproved(zeroHash);
      await flow
        .getByRole("button", { name: "Post floor", exact: true })
        .click();
      await expect(
        flow
          .getByRole("alert")
          .filter({ hasText: "no longer approved" })
          .or(
            flow.getByRole("button", {
              name: "Approve this hash",
              exact: true,
            }),
          ),
      ).toBeVisible();
      expect(t.world.sends).toHaveLength(0);
      await t.context.close();
    },
  );
  await check(
    "Below $1M shows the signed value and no pin or burn; tampered and stale answers are rejected",
    async () => {
      const t = await setup();
      await t.answer("cap", 999999n * 10n ** 18n);
      let flow = await fetchAnswer(t, "cap");
      await expect(flow).toContainText("$999,999 / $1,000,000");
      await expect(flow).toContainText("milestone has not been reached");
      await expect(
        flow.getByRole("button", { name: "Pin this answer", exact: true }),
      ).toHaveCount(0);
      await expect(
        flow.getByRole("button", { name: "Burn", exact: true }),
      ).toHaveCount(0);
      await t.answer("cap", BURN_MILESTONE, 3601);
      flow = await fetchAnswer(t, "cap");
      await expect(flow.getByRole("alert")).toContainText("over 1 hour old");
      const ev = await t.answer("cap");
      ev.typed.message.answer = encodeAbiParameters(
        parseAbiParameters("uint256"),
        [BURN_MILESTONE * 2n],
      );
      flow = await fetchAnswer(t, "cap");
      await expect(flow.getByRole("alert")).toContainText(
        "Invalid oracle signature",
      );
      expect(t.world.sends).toHaveLength(0);
      await t.context.close();
    },
  );
  await check(
    "At exactly $1M the setter pins once, then Burn becomes available and uses the verified evidence",
    async () => {
      const t = await setup();
      await t.answer("cap");
      const flow = await fetchAnswer(t, "cap");
      await expect(flow.getByRole("timer")).toContainText(/59m|60m/);
      await transaction(flow, "Pin this answer");
      await expect(
        flow.getByRole("button", { name: "Burn", exact: true }),
      ).toBeEnabled({ timeout: 15000 });
      expect(t.world.sends.map((x) => x.fn)).toEqual(["setQuestionHashOnce"]);
      expect(t.world.sends[0].args).toEqual([hash]);
      await transaction(flow, "Burn");
      await expect(
        flow.getByText("The one-time burn has already completed."),
      ).toBeVisible({ timeout: 15000 });
      expect(t.world.sends.map((x) => x.fn)).toEqual([
        "setQuestionHashOnce",
        "burn",
      ]);
      expect(t.world.sends[1].args[0].questionHash).toEqual(hash);
      await t.context.close();
    },
  );
  await check(
    "Immutable setter can re-pin from the public Burn section even when not the PawnShop owner",
    async () => {
      const t = await setup({
        account: other,
        setter: other,
        burnHash: `0x${"dd".repeat(32)}`,
        route: "#oracle",
      });
      await t.answer("cap", BURN_MILESTONE * 2n);
      const flow = await fetchAnswer(t, "cap");
      await transaction(flow, "Pin this answer");
      await expect(
        flow.getByRole("button", { name: "Burn", exact: true }),
      ).toBeEnabled({ timeout: 15000 });
      expect(t.world.sends.map((x) => x.fn)).toEqual(["replaceQuestionHash"]);
      await t.context.close();
    },
  );
  await check(
    "Non-setter waits for pin; countdown respects earlier signed expiry and disables an open review",
    async () => {
      const visitor = await setup({ account: other, route: "#oracle" });
      await visitor.answer("cap");
      const visitorFlow = await fetchAnswer(visitor, "cap");
      await expect(
        visitorFlow.getByText(/Waiting for the question setter/),
      ).toBeVisible();
      await expect(
        visitorFlow.getByRole("button", {
          name: "Pin this answer",
          exact: true,
        }),
      ).toHaveCount(0);
      await visitor.context.close();
      const t = await setup({ burnHash: hash });
      await t.page.clock.install();
      await t.answer("cap", BURN_MILESTONE, 0, 30);
      const flow = await fetchAnswer(t, "cap");
      await expect(flow.getByRole("timer")).toContainText(/0m (2|3)/);
      await flow.getByRole("button", { name: "Burn", exact: true }).click();
      await expect(
        flow.getByRole("button", { name: "Confirm burn", exact: true }),
      ).toBeEnabled();
      t.tick(31);
      await t.page.clock.fastForward(31000);
      await expect(flow.getByRole("timer")).toContainText("Expired");
      await expect(
        flow.getByRole("button", { name: "Confirm burn", exact: true }),
      ).toBeDisabled();
      expect(t.world.sends).toHaveLength(0);
      await t.context.close();
    },
  );
  await check(
    "Responsive Setup, keyboard review, reduced motion, risk disclosures and automated accessibility",
    async () => {
      const t = await setup();
      await t.answer("cap", BURN_MILESTONE * 2n);
      const flow = await fetchAnswer(t, "cap");
      await expect(
        flow.getByRole("button", { name: "Pin this answer", exact: true }),
      ).toBeEnabled();
      for (const width of [320, 390, 800, 1440]) {
        await t.page.setViewportSize({ width, height: 1000 });
        const noOverflow = await t.page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        );
        report.viewports.push({ width, noOverflow });
        expect(noOverflow).toBeTruthy();
      }
      await t.page.setViewportSize({ width: 1440, height: 1000 });
      await t.page.screenshot({
        path: resolve(out, "setup-desktop.jpg"),
        type: "jpeg", quality: 75, fullPage: true,
      });
      await t.page.setViewportSize({ width: 390, height: 844 });
      await t.page.screenshot({
        path: resolve(out, "setup-mobile.jpg"),
        type: "jpeg", quality: 75, fullPage: true,
      });
      await flow.screenshot({ path: resolve(out, "burn-flow-mobile.png") });
      const pin = flow.getByRole("button", {
        name: "Pin this answer",
        exact: true,
      });
      await pin.focus();
      await t.page.keyboard.press("Shift+Tab");
      await t.page.keyboard.press("Tab");
      await expect(pin).toBeFocused();
      await t.page.screenshot({ path: resolve(out, "keyboard-focus.png") });
      await t.page.keyboard.press("Enter");
      await expect(flow.getByText("Review transaction")).toBeVisible();
      await t.page.keyboard.press("Tab");
      await t.page.keyboard.press("Tab");
      await t.page.keyboard.press("Tab");
      await expect(
        flow.getByRole("button", {
          name: "Confirm pin this answer",
          exact: true,
        }),
      ).toBeFocused();
      await t.page.keyboard.press("Tab");
      await t.page.keyboard.press("Enter");
      await expect(flow.getByText("Review transaction")).toHaveCount(0);
      expect(t.world.sends).toHaveLength(0);
      const axe = await new AxeBuilder({ page: t.page }).analyze();
      report.accessibility.push({
        route: "#setup",
        violations: axe.violations,
      });
      expect(axe.violations).toEqual([]);
      report.contrasts = await t.page.evaluate(() => {
        const lum = (color: string) =>
          (color.match(/[\d.]+/g) ?? [])
            .slice(0, 3)
            .map(Number)
            .map((x) => x / 255)
            .map((x) =>
              x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4,
            )
            .reduce((s, x, i) => s + x * [0.2126, 0.7152, 0.0722][i], 0);
        return [
          ".oracle-flow > p",
          ".oracle-flow .muted",
          ".oracle-flow button",
          ".oracle-flow .notice.warning",
          ".oracle-answer code",
        ].map((selector) => {
          const el = document.querySelector(selector)!;
          const style = getComputedStyle(el);
          let parent: Element | null = el;
          let bg = "";
          while (parent) {
            bg = getComputedStyle(parent).backgroundColor;
            if (bg !== "rgba(0, 0, 0, 0)" && bg !== "transparent") break;
            parent = parent.parentElement;
          }
          const a = lum(style.color),
            b = lum(bg);
          return {
            selector,
            foreground: style.color,
            background: bg,
            ratio: (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05),
          };
        });
      });
      for (const item of report.contrasts)
        expect(item.ratio).toBeGreaterThanOrEqual(4.5);
      await t.page.emulateMedia({ reducedMotion: "reduce" });
      expect(
        await pin.evaluate((el) => getComputedStyle(el).transitionDuration),
      ).toBe("0s");
      for (const summary of [
        "Borrowing & collateral risks",
        "Owner powers & oracle trust",
        "Fees, bounties & burn",
      ])
        await t.page.getByText(summary, { exact: true }).click();
      await expect(t.page.locator(".risk-section")).toContainText(
        "fresh floor answer",
      );
      await expect(t.page.locator(".risk-section")).toContainText(
        "admits each new floor request’s hash immediately",
      );
      await expect(t.page.locator(".risk-section")).toContainText(
        "under 1 hour old",
      );
      await t.context.close();
    },
  );
  expect(report.consoleErrors).toEqual([]);
  expect(report.failedResources).toEqual([]);
  report.result = "passed";
} catch (e: any) {
  report.result = "failed";
  report.error = e.message;
  process.exitCode = 1;
  console.error(e);
} finally {
  writeFileSync(
    resolve(out, "browser-results.json"),
    JSON.stringify(report, null, 2) + "\n",
  );
  await browser.close();
  server.closeAllConnections();
  await new Promise<void>((r) => server.close(() => r()));
}
