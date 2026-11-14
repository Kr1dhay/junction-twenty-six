import { test, expect } from "@playwright/test";

// The map needs WebGL and remote tiles; the simulation, explanations and rankings must work without either.
for (const width of [1600, 390]) {
  test(`digital twin explains each step and suggests places at ${width}px`, async ({ page }) => {
    test.setTimeout(300_000);
    await page.setViewportSize({ width, height: 1000 });
    await page.route(/tiles\.openfreemap\.org/, route => route.abort());
    await page.goto("/");
    await page.getByRole("link", { name: "Digital twin", exact: true }).click();
    await expect(page).toHaveURL(/\/digital-twin$/);
    const twin = page.getByRole("region", { name: "Where would one more resource help most?" });
    await expect(twin.getByText(/No nationality, citizenship or immigration status/)).toBeVisible();
    const feed = twin.getByRole("region", { name: "What just happened" });
    await expect(feed.getByRole("heading", { name: "Start here" })).toBeVisible();

    await twin.getByRole("button", { name: /Interpreter/ }).click();
    await expect(feed.getByRole("heading", { name: /One on-site interpreter/ })).toBeVisible();
    await expect(twin.getByRole("button", { name: "Who may need an interpreter?" })).toHaveAttribute("aria-pressed", "true");

    const run = twin.getByRole("button", { name: /^Simulate [\d,]+ scenarios$/ });
    await expect(run).toBeEnabled({ timeout: 90_000 });
    await run.click();
    await expect(feed.getByRole("heading", { name: /^Best place: / })).toBeVisible({ timeout: 200_000 });
    const results = twin.getByRole("region", { name: /Best places for one on-site interpreter/ });
    await expect(results.getByRole("listitem")).toHaveCount(8);
    await expect(results.getByRole("button", { pressed: true })).toHaveCount(1);

    await twin.getByRole("checkbox", { name: /Snowstorm/ }).check();
    await expect(feed.getByRole("heading", { name: /Snowstorm/ })).toBeVisible();
    await expect(feed.getByText(/People more than 30 minutes from a health station by car: [\d,]+ → [\d,]+/)).toBeVisible();
    await expect(results).toHaveCount(0);

    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(overflow).toBeLessThanOrEqual(0);
  });
}
