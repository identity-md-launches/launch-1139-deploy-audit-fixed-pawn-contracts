import { createServer } from "node:http";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, extname } from "node:path";
import { chromium, expect } from "@playwright/test";
const root = resolve(import.meta.dirname, "../.."),
  out = resolve(root, "docs/frontend/relaunch");
const verified = JSON.parse(
  readFileSync(resolve(out, "mainnet-verification.json")),
);
const server = createServer((req, res) => {
  try {
    const path = (req.url ?? "").split("?")[0];
    if (!path.startsWith("/preview/") || path.includes(".."))
      throw Error("Not found");
    const file = resolve(root, "dist", path.slice(9) || "index.html");
    res.setHeader(
      "Content-Type",
      {
        ".html": "text/html",
        ".js": "application/javascript",
        ".json": "application/json",
        ".css": "text/css",
        ".svg": "image/svg+xml",
        ".ttf": "font/ttf",
      }[extname(file)] ?? "application/octet-stream",
    );
    res.end(readFileSync(file));
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const browser = await chromium.launch({
  headless: true,
  args: ["--no-sandbox"],
});
const report = {
  checkedAt: new Date().toISOString(),
  browser: browser.version(),
  mode: "Local production dist at /preview/, real public mainnet RPC reads. A read-only wallet adapter exposes the verified public owner address for Setup; all signing methods throw. This is not hosted-site publication.",
  consoleErrors: [],
  failedResources: [],
  screenshots: [],
  viewports: [],
};
try {
  const page = await browser.newPage({
    viewport: { width: 1440, height: 1050 },
  });
  page.on("pageerror", (e) => report.consoleErrors.push(e.message));
  page.on("requestfailed", (r) =>
    report.failedResources.push({
      url: r.url(),
      error: r.failure()?.errorText,
    }),
  );
  await page.addInitScript((address) => {
    window.ethereum = {
      on: () => {},
      removeListener: () => {},
      request: async ({ method }) => {
        if (["eth_requestAccounts", "eth_accounts"].includes(method))
          return [address];
        if (method === "eth_chainId") return "0x1";
        throw Error(
          "Read-only validation: signing and wallet mutations are disabled",
        );
      },
    };
  }, verified.state.owner);
  await page.goto(`http://127.0.0.1:${server.address().port}/preview/`);
  await expect(page.getByText(/Contract reads verified/)).toBeVisible({
    timeout: 45000,
  });
  report.initialHealth = await page.locator(".health-bar").innerText();
  await page
    .getByRole("button", { name: "Connect wallet", exact: true })
    .click();
  await expect(
    page.getByRole("link", { name: "Setup", exact: true }),
  ).toBeVisible({ timeout: 45000 });
  await page.getByRole("link", { name: "Setup", exact: true }).click();
  await expect(page.locator(".setup-contracts")).toContainText(
    "0xf0d9300d7d891bc842da540cc4ddef050da9bcd4",
  );
  await expect(
    page.getByText("Pending verified factory read", { exact: true }),
  ).toHaveCount(0, { timeout: 30000 });
  await expect(page.locator(".setup-contracts")).toContainText(
    "Launch factory",
  );
  await expect(page.locator(".setup-contracts")).toContainText(
    "MerkleDistributor",
  );
  report.tradingFeeProvenance =
    "Original token launch receipt, factory position and claimFees eth_call verified; no transaction sent";
  report.setupContracts = await page.locator(".setup-contracts").innerText();
  for (const name of [
    "LendingPool",
    "LockDiscount",
    "VaultFactory",
    "FloorRelay",
    "MilestoneBurn",
  ]) {
    const expected = verified.contracts.find((c) => c.name === name).address;
    await expect(page.locator(".setup-contracts")).toContainText(
      new RegExp(expected, "i"),
    );
  }
  await expect(
    page
      .getByText(
        "FloorRelay is active. Answers signed with no consumer are accepted.",
      )
      .first(),
  ).toBeVisible({ timeout: 30000 });
  for (const width of [320, 390, 800, 1440]) {
    await page.setViewportSize({ width, height: 1050 });
    const noOverflow = await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    );
    report.viewports.push({ width, noOverflow });
    expect(noOverflow).toBeTruthy();
  }
  await page
    .locator(".setup-contracts")
    .screenshot({ path: resolve(out, "live-mainnet-contracts.png") });
  report.screenshots.push("docs/frontend/relaunch/live-mainnet-contracts.png");
  report.liveSetupPawnShopConfirmedLocally = true;
  report.result = "passed";
} catch (e) {
  report.result = "failed";
  report.error = e.message;
  process.exitCode = 1;
  console.error(e.message);
} finally {
  mkdirSync(out, { recursive: true });
  writeFileSync(
    resolve(out, "live-browser.json"),
    JSON.stringify(report, null, 2) + "\n",
  );
  console.log(JSON.stringify(report, null, 2));
  await browser.close();
  server.closeAllConnections();
  await new Promise((r) => server.close(r));
}
