import { test, expect } from "@playwright/test";

for (const width of [1600, 390]) {
  test(`equity cards show evidence, scenario transitions and AI states at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    await page.goto("/");
    await page.getByRole("button", { name: "Enter clinician demo" }).click();
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

test("equity page requires a clinician session", async ({ page }) => {
  await page.goto("/equity-actions");
  await expect(page.getByRole("button", { name: "Enter clinician demo" })).toBeVisible();
  await expect(page.getByRole("region", { name: "What should we do?" })).toHaveCount(0);
});
