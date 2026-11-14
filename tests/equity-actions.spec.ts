import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";

// The browser server runs with EDGECARE_PUBLIC_DATA=snapshot, so every figure comes from the committed snapshot.
type Cell = { value: number; count?: number } | null;
const snapshot = JSON.parse(readFileSync("apps/crm-web/src/lib/pathway-snapshot.json", "utf8")) as {
  regions: { id: number; name: string }[]; indicators: Record<string, { national: { value: number }; values: Record<string, Cell> }>;
};
const helsinki = snapshot.regions.find(region => region.name === "Helsinki")!;
const breast = snapshot.indicators[3621]!;
const helsinkiBreast = breast.values[helsinki.id]!;

for (const width of [1600, 390]) {
  test(`equity page briefs a county from public data at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "Anonymous referrals", exact: true })).toBeVisible();
    await expect(page.getByRole("region", { name: "What should we do?" })).toHaveCount(0);
    await page.getByRole("link", { name: "Equity actions", exact: true }).click();
    await expect(page).toHaveURL(/\/equity-actions$/);
    await expect(page.getByRole("link", { name: "Equity actions", exact: true })).toHaveAttribute("aria-current", "page");
    await expect(page.getByRole("heading", { level: 1, name: "What should we do?" })).toBeVisible();
    const section = page.getByRole("region", { name: "What should we do?" });
    await expect(section.getByText(/Public county data · THL Sotkanet/)).toBeVisible();
    await expect(section.getByText(/Saved copy from/)).toBeVisible();
    await expect(section.getByRole("combobox", { name: "County" })).toHaveValue(String(helsinki.id));

    const brief = section.getByRole("region", { name: /Helsinki: the gap, where it opens, what to do/ });
    await expect(brief.getByRole("listitem")).toHaveCount(3);
    await expect(brief).toContainText("Helsinki is furthest behind on");
    await expect(brief).toContainText(/ranking \d+ of \d+ counties/);

    const overview = section.getByRole("region", { name: "Where does Helsinki fall behind?" });
    await expect(overview.getByRole("listitem")).toHaveCount(5);
    await expect(overview.getByText("Furthest behind", { exact: true })).toHaveCount(1);
    const behind = Number((await overview.getByRole("status").innerText()).match(/(\d) \/ 5/)![1]);
    expect(behind).toBeGreaterThan(0);
    await expect(section.locator("article")).toHaveCount(behind);
    await expect(section.locator("article").first().getByText("Furthest behind", { exact: true })).toBeVisible();
    await expect(section.getByRole("complementary", { name: "Referral timing in this workspace" })).toContainText("Open referrals");

    const card = section.getByRole("article", { name: "Make screening invitations easier to act on" });
    await overview.getByRole("link", { name: /Screening/ }).click();
    await expect(page).toHaveURL(/#plan-screening$/);
    await expect(card).toBeFocused();
    const chart = card.getByRole("figure", { name: /Helsinki compared with Finland/ });
    await expect(chart).toContainText(`${helsinkiBreast.value}%`);
    await expect(chart).toContainText(`${breast.national.value}%`);
    await expect(chart).toContainText(/rank \d+ of \d+/);
    await card.getByText("Why this fits & implementation plan", { exact: true }).click();
    await expect(card.getByText("Resources to agree locally")).toBeVisible();
    await expect(card.locator(".equity-evidence > a")).toHaveAttribute("href", "https://stacks.cdc.gov/view/cdc/164181");
    await expect(card.locator("time")).toHaveAttribute("datetime", "2024-05-17");
    await expect(card.getByText("PILOT TARGET · NOT A PREDICTED EFFECT")).toBeVisible();

    await card.getByRole("combobox", { name: "Programme" }).selectOption("3621");
    const invited = Math.round(helsinkiBreast.count! / (helsinkiBreast.value / 100));
    const needed = Math.ceil(invited * 0.8) - helsinkiBreast.count!;
    await expect(card).toContainText(`${needed.toLocaleString("en-GB")} more attendances`);
    await expect(card.getByRole("status")).toContainText(`Participation ${helsinkiBreast.value}% · 0 more people · still below the 80% target`);
    await card.getByRole("slider").fill("50");
    await expect(card.getByRole("status")).toContainText("reaches the 80% target");

    await page.route("**/demo/equity/explain", route => route.fulfill({ status: 503, json: { error: "Unavailable" } }));
    await brief.getByRole("button", { name: "Explain with AI" }).click();
    await expect(brief.getByRole("alert")).toContainText("data-based brief above is unaffected");
    await page.unroute("**/demo/equity/explain");
    let sent: unknown;
    await page.route("**/demo/equity/explain", route => { sent = route.request().postDataJSON(); return route.fulfill({ json: {
      explanation: "Synthetic test explanation: adapt navigation to local services.", evidence_ids: ["navigation"],
    } }); });
    await brief.getByRole("button", { name: "Explain with AI" }).click();
    await expect(brief.getByText("AI-assisted explanation · review required")).toBeVisible();
    expect(sent).toEqual({ region: helsinki.id, basis: "snapshot" });

    const ranking = section.getByRole("region", { name: "How every county compares" });
    await expect(ranking.getByRole("listitem")).toHaveCount(snapshot.regions.length);
    await expect(ranking.getByRole("button", { name: /Helsinki/ })).toHaveAttribute("aria-pressed", "true");
    await ranking.getByRole("combobox", { name: "Measure" }).selectOption("3627");
    await expect(ranking).toContainText("Higher is better");
    await ranking.getByRole("button", { name: /Kainuu/ }).click();
    await expect(page).toHaveURL(/\?county=\d+/);
    await expect(section.getByRole("region", { name: /Kainuu: the gap, where it opens, what to do/ })).toBeVisible();
    await expect(section.getByText("AI-assisted explanation · review required")).toHaveCount(0);
    await expect(section.getByText(/Small population/)).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.reload();
    await expect(section.getByRole("region", { name: /Kainuu: the gap/ })).toBeVisible();
    await page.getByRole("link", { name: "All referrals", exact: true }).click();
    await expect(page.getByRole("heading", { name: "Anonymous referrals", exact: true })).toBeVisible();
  });
}

test("referral list shows waiting clocks and sorts by longest wait", async ({ page }) => {
  await page.goto("/");
  const strip = page.getByLabel("Waiting times");
  await expect(strip).toContainText("Longest open wait");
  await expect(strip).toContainText("Median time to verification");
  const open = page.locator(".referral-row", { has: page.locator(".status-label.open") });
  await expect(open.first().locator(".wait-chip")).toHaveText(/waiting \d+ (min|h|d)/i);
  await page.getByRole("combobox", { name: "Sort referrals" }).selectOption("waiting");
  await expect(page.locator(".referral-row").first().locator(".status-label")).toHaveClass(/open/);
  await expect(page.getByLabel("Selected referral details")).toContainText(/Waiting|Time to verification/);
});

test("equity page opens through automatic demo entry", async ({ page }) => {
  await page.goto("/equity-actions");
  await expect(page.getByRole("heading", { level: 1, name: "What should we do?" })).toBeVisible();
  await expect(page.locator('input[type="password"]')).toHaveCount(0);
});

test("failed demo entry does not expose the equity page", async ({ page }) => {
  await page.route("**/demo/session", route => route.fulfill({ status: 503, json: { error: "Unavailable" } }));
  await page.goto("/equity-actions");
  await expect(page.getByRole("alert").filter({ hasText: "Unable to open" })).toBeVisible();
  await expect(page.getByRole("region", { name: "What should we do?" })).toHaveCount(0);
});
