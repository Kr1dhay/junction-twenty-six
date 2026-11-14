import { test, expect } from "@playwright/test";

// The map needs WebGL and remote tiles; the simulation, results and tables must work without either.
for (const width of [1600, 390]) {
  test(`digital twin runs scenarios and suggests placements at ${width}px`, async ({ page }) => {
    test.setTimeout(120_000);
    await page.setViewportSize({ width, height: 1000 });
    await page.route(/tiles\.openfreemap\.org/, route => route.abort());
    await page.goto("/");
    await page.getByRole("link", { name: "Digital twin", exact: true }).click();
    await expect(page).toHaveURL(/\/digital-twin$/);
    await expect(page.getByRole("link", { name: "Digital twin", exact: true })).toHaveAttribute("aria-current", "page");
    const twin = page.getByRole("region", { name: "Where would one more resource help most?" });
    await expect(twin).toBeVisible();
    await expect(twin.getByRole("img", { name: /3D map of Helsinki/ })).toBeAttached();
    await expect(twin.getByRole("heading", { name: "What this twin does not contain" })).toBeVisible();
    await expect(twin.getByText(/No nationality, citizenship or immigration status/)).toBeVisible();

    const run = twin.getByRole("button", { name: /^Run [\d,]+ scenarios$/ });
    const label = await run.textContent();
    const count = Number(label!.replace(/\D/g, ""));
    expect(count).toBeGreaterThan(10_000);
    await run.click();
    const results = twin.getByRole("region", { name: "Best place for one more…" });
    await expect(results).toBeVisible({ timeout: 60_000 });
    await expect(twin.getByText(`${count.toLocaleString("en-GB")} scenarios:`)).toBeVisible();
    await expect(results.getByRole("article")).toHaveCount(3);
    await expect(results.getByRole("article").first()).toContainText("of the city's access gap closed");
    await expect(results.getByRole("button", { name: "Shown on map" })).toHaveCount(1);
    await expect(twin.getByRole("group", { name: "Map shows" })).toBeVisible();

    // A transit strike is a new scenario: results clear until it is run again.
    await twin.getByRole("checkbox", { name: "Public transport strike" }).check();
    await expect(results).toHaveCount(0);

    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(overflow).toBeLessThanOrEqual(0);
  });
}
