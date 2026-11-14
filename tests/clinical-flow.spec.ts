import { test, expect } from "@playwright/test";
import { createDecipheriv, createHash, hkdfSync, randomUUID } from "node:crypto";
import { mkdirSync, readFileSync } from "node:fs";

function enrollment() {
  const record = JSON.parse(readFileSync("packages/shared-types/fixtures/referrals.json", "utf8"))[0];
  const salt = Buffer.from(record.salt, "base64");
  const key = Buffer.from(hkdfSync("sha256", Buffer.from("1234"), salt, Buffer.from("edgecare.referral.v1"), 32));
  const sealed = Buffer.from(record.signature_template_encrypted, "base64");
  const cipher = createDecipheriv("aes-256-gcm", key, sealed.subarray(0, 12));
  cipher.setAuthTag(sealed.subarray(-16));
  const template = Buffer.concat([cipher.update(sealed.subarray(12, -16)), cipher.final()]);
  record.referral_id = randomUUID();
  record.created_at = new Date().toISOString();
  record.expires_at = new Date(Date.now() + 30 * 86_400_000).toISOString();
  record.free_text_summary = "Synthetic browser integration: a concern for clinician review.";
  record.commitment_hash = createHash("sha256").update(Buffer.concat([createHash("sha256").update(template).digest(), Buffer.from("1234"), Buffer.from(record.referral_id), salt])).digest("hex");
  return record;
}

test("clinician sees enrollment arrive, single-use spend propagate and stale data clearly marked", async ({ page, request, context }) => {
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Anonymous referrals", exact: true })).toBeVisible();
  await expect(page.locator('input[type="password"]')).toHaveCount(0);
  await expect(page.locator(".referral-row")).toHaveCount(3);
  await page.getByRole("combobox", { name: "Risk band", exact: true }).selectOption("high");
  await expect(page.locator(".referral-row")).toHaveCount(1);
  await page.getByRole("button", { name: "Clear filters", exact: true }).click();
  await expect(page.locator(".referral-row")).toHaveCount(3);
  const record = enrollment();
  const created = await request.put(`/demo/commitments/${record.referral_id}`, { data: { commitment_hash: record.commitment_hash } });
  expect(created.ok()).toBeTruthy();
  expect((await request.post("/referrals", { data: record })).status()).toBe(201);
  await expect(page.locator(".referral-row")).toHaveCount(4);
  await page.getByRole("searchbox", { name: "Search referrals" }).fill(record.referral_id);
  await expect(page.locator(".referral-row")).toHaveCount(1);
  await expect(page.locator(".detail-id code")).toHaveText(record.referral_id);
  const publicRecord = await (await request.get(`/referrals/${record.referral_id}`)).json();
  expect(publicRecord).not.toHaveProperty("salt");
  expect(publicRecord).not.toHaveProperty("signature_template_encrypted");
  const operation_id = randomUUID();
  const body = { commitment_hash: record.commitment_hash, operation_id };
  expect((await request.post(`/demo/commitments/${record.referral_id}/spend`, { data: body })).status()).toBe(200);
  await expect(page.getByText("Verification accepted", { exact: true })).toBeVisible();
  await expect(page.locator(".referral-row .status-label")).toContainText("Verified");
  expect((await request.post(`/demo/commitments/${record.referral_id}/spend`, { data: body })).status()).toBe(200);
  expect((await request.post(`/demo/commitments/${record.referral_id}/spend`, { data: { ...body, operation_id: randomUUID() } })).status()).toBe(409);
  await page.getByRole("searchbox", { name: "Search referrals" }).fill("");
  mkdirSync("artifacts/browser", { recursive: true });
  await page.screenshot({ path: "artifacts/browser/doctor-crm-desktop.png", fullPage: true });
  await context.setOffline(true);
  await page.getByRole("button", { name: "Refresh", exact: true }).click();
  await expect(page.locator(".error-banner[role=alert]")).toContainText(/Unable to reach|Failed to fetch|Connection/i);
  await expect(page.locator(".referral-row")).toHaveCount(4);
  await context.setOffline(false);
  await page.getByRole("button", { name: "Refresh", exact: true }).click();
  await expect(page.locator(".error-banner[role=alert]")).toHaveCount(0);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: "artifacts/browser/doctor-crm-mobile.png", fullPage: true });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBeTruthy();
  const filterBounds = await page.locator(".filters label").evaluateAll(labels => labels.map(label => {
    const rect = label.getBoundingClientRect();
    return { x: rect.x, y: rect.y, right: rect.right, bottom: rect.bottom, width: rect.width };
  }));
  for (let i = 0; i < filterBounds.length; i++) {
    expect(filterBounds[i]!.width).toBeGreaterThan(100);
    for (let j = i + 1; j < filterBounds.length; j++) {
      const a = filterBounds[i]!, b = filterBounds[j]!;
      expect(a.x < b.right && a.right > b.x && a.y < b.bottom && a.bottom > b.y).toBeFalsy();
    }
  }
  await page.setViewportSize({ width: 844, height: 1100 });
  await context.clearCookies();
  await page.getByRole("button", { name: "Refresh", exact: true }).click();
  await expect.poll(async () => (await context.cookies()).some(cookie => cookie.name === "edgecare_demo_session")).toBeTruthy();
  await expect(page.getByRole("heading", { name: "Anonymous referrals", exact: true })).toBeVisible();
  await expect(page.locator(".referral-row")).toHaveCount(4);
  expect(errors).toEqual([]);
});

test("automatic CRM entry can retry a failed session request without a code", async ({ page }) => {
  let attempts = 0;
  await page.route("**/demo/session", async route => {
    attempts++;
    if (attempts === 1) await route.fulfill({ status: 503, json: { error: "Synthetic test outage" } });
    else await route.continue();
  });
  await page.goto("/");
  await expect(page.locator(".error-banner[role=alert]")).toContainText("Unable to open the demo workspace");
  await expect(page.locator('input[type="password"]')).toHaveCount(0);
  await page.getByRole("button", { name: "Try again", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Anonymous referrals", exact: true })).toBeVisible();
  expect(attempts).toBe(2);
});
