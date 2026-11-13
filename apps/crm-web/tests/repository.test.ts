import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DemoRepository } from "../src/server/repository";
import { demoReferrals } from "@edgecare/shared-types/fixtures";
const record = demoReferrals[0]!;
const now = () => new Date("2026-11-14T12:00:00.000Z");

test("submission is idempotent and rejects changed payloads", () => {
  const store = new DemoRepository(":memory:", now);
  try {
    assert.deepEqual(store.create(record), { created: true });
    assert.deepEqual(store.create(record), { created: false });
    assert.throws(() => store.create({ ...record, risk_score: 0 }), /different content/);
    assert.equal(store.list().length, 1);
  } finally { store.close(); }
});
test("registry reconciles spent status and rejects double spending", () => {
  const store = new DemoRepository(":memory:", now);
  try {
    store.create(record); store.create(record.referral_id, record.commitment_hash);
    store.create(record.referral_id, record.commitment_hash);
    assert.throws(() => store.create(record.referral_id, "f".repeat(64)), /different content/);
    assert.equal(store.get(record.referral_id)?.status, "open");
    store.spend(record.referral_id);
    assert.equal(store.get(record.referral_id)?.status, "spent");
    assert.deepEqual(store.get(record.referral_id)?.status_history.at(-1), { status: "spent", at: now().toISOString() });
    assert.throws(() => store.spend(record.referral_id), /already spent/);
    assert.throws(() => store.spend("missing"), /missing/);
  } finally { store.close(); }
});
test("expiry is derived; spent remains spent after expiry", () => {
  const store = new DemoRepository(":memory:", () => new Date("2031-01-01T00:00:00.000Z"));
  try {
    store.create(record); assert.equal(store.get(record.referral_id)?.status, "expired");
    store.create(record.referral_id, record.commitment_hash); store.spend(record.referral_id);
    assert.equal(store.get(record.referral_id)?.status, "spent");
  } finally { store.close(); }
});
test("records and spend flags survive reopening the database", () => {
  const folder = mkdtempSync(join(tmpdir(), "edgecare-test-"));
  const path = join(folder, "db.sqlite");
  try {
    const first = new DemoRepository(path, now);
    first.create(record); first.create(record.referral_id, record.commitment_hash); first.spend(record.referral_id); first.close();
    const second = new DemoRepository(path, now);
    try { assert.equal(second.get(record.referral_id)?.status, "spent"); } finally { second.close(); }
  } finally { rmSync(folder, { recursive: true, force: true }); }
});
