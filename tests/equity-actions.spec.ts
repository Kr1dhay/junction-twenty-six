import { test, expect } from "@playwright/test";

for (const width of [1600, 390]) {
  test(`equity cards show evidence, scenario transitions and AI states at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "Anonymous referrals", exact: true })).toBeVisible();
    await expect(page.getByRole("region", { name: "What should we do?" })).toHaveCount(0);
    await page.getByRole("link", { name: "Equity actions", exact: true }).click();
    await expect(page).toHaveURL(/\/equity-actions$/);
    await expect(page.getByRole("link", { name: "Equity actions", exact: true })).toHaveAttribute("aria-current", "page");
    await expect(page.getByRole("heading", { level: 1, name: "What should we do?" })).toBeVisible();
    const section = page.getByRole("region", { name: "What should we do?" });
    await expect(section).toBeVisible();
    await section.scrollIntoViewIfNeeded();
    await expect(section.locator("article")).toHaveCount(3);
    await expect(section.locator(".equity-gap > strong").first()).toHaveText("16.0 pp");
    const card = section.getByRole("article", { name: "Make screening invitations easier to act on" });
    await expect(section.getByRole("status")).toHaveText("3 / 3 stages with a scenario gap");
    const screeningChart = card.getByRole("figure", { name: /Cohort comparison/ });
    await expect(screeningChart).toContainText("112 of 200");
    await expect(screeningChart).toContainText("56%");
    await expect(screeningChart).toContainText("72%");
    const bars = screeningChart.locator('[aria-hidden="true"] > span[style]');
    expect(await bars.nth(0).evaluate(element => parseFloat((element as HTMLElement).style.width))).toBeCloseTo(56);
    expect(await bars.nth(1).evaluate(element => parseFloat((element as HTMLElement).style.width))).toBeCloseTo(72);
    await section.getByRole("link", { name: /01.*Screening participation/ }).click();
    await expect(page).toHaveURL(/#plan-screening$/);
    await expect(card).toBeFocused();
    await card.getByText("Why this fits & implementation plan", { exact: true }).click();
    await expect(card.getByText("Resources to agree locally")).toBeVisible();
    await expect(card.getByRole("link")).toHaveAttribute("href", "https://stacks.cdc.gov/view/cdc/164181");
    await expect(card.locator("time")).toHaveAttribute("datetime", "2024-05-17");
    await expect(card.getByText("PILOT TARGET · NOT A PREDICTED EFFECT")).toBeVisible();

    await page.route("**/demo/equity/explain", route => route.fulfill({ status: 503, json: { error: "Unavailable" } }));
    await card.getByRole("button", { name: "Explain this plan with AI" }).click();
    await expect(card.getByRole("alert")).toContainText("reviewed plan remains available");
    await page.unroute("**/demo/equity/explain");
    await page.route("**/demo/equity/explain", route => route.fulfill({ json: {
      explanation: "Synthetic test explanation: adapt navigation to local services.", evidence_ids: ["navigation"],
    } }));
    await card.getByRole("button", { name: "Explain this plan with AI" }).click();
    await expect(card.getByText("AI-assisted explanation · review required")).toBeVisible();
    await expect(card.locator(".equity-gap > strong")).toHaveText("16.0 pp");
    await section.getByRole("combobox", { name: "Explore a scenario" }).selectOption("improved");
    await expect(section.getByText("No gap detected", { exact: true })).toHaveCount(3);
    await expect(section.getByRole("status")).toHaveText("0 / 3 stages with a scenario gap");
    await expect(card.getByRole("figure")).toContainText("144 of 200");
    await expect(section.getByText("6 pp above the proposed target")).toBeVisible();
    await expect(section.getByRole("button", { name: "Explain this plan with AI" })).toHaveCount(0);
    await section.getByRole("combobox", { name: "Explore a scenario" }).selectOption("baseline");
    await expect(section.getByText("AI-assisted explanation · review required")).toHaveCount(0);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.reload();
    await expect(page.getByRole("heading", { level: 1, name: "What should we do?" })).toBeVisible();
    await page.getByRole("link", { name: "All referrals", exact: true }).click();
    await expect(page.getByRole("heading", { name: "Anonymous referrals", exact: true })).toBeVisible();
  });
}

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
