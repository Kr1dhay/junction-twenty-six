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
    assert.throws(() => store.spend("missing"), /not found/);
  } finally { store.close(); }
});
test("expired referrals cannot be spent; an accepted spend remains spent after expiry", () => {
  let instant = new Date("2026-11-14T12:00:00.000Z");
  const store = new DemoRepository(":memory:", () => instant);
  try {
    const expired = { ...record, referral_id: "99999999-9999-4999-8999-999999999999", expires_at: "2026-11-14T10:00:00.000Z" };
    store.create(expired); store.create(expired.referral_id, expired.commitment_hash);
    assert.equal(store.get(expired.referral_id)?.status, "expired");
    assert.throws(() => store.spend(expired.referral_id), /expired/);
    store.create(record); store.create(record.referral_id, record.commitment_hash); store.spend(record.referral_id);
    instant = new Date("2031-01-01T00:00:00.000Z");
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

test("hash consistency is checked regardless of upload order", () => {
  const store = new DemoRepository(":memory:", now);
  try {
    store.create(record.referral_id, "f".repeat(64));
    assert.throws(() => store.create(record), /does not match/);
    const other = { ...record, referral_id: "77777777-7777-4777-8777-777777777777" };
    store.create(other);
    assert.throws(() => store.create(other.referral_id, "f".repeat(64)), /does not match/);
  } finally { store.close(); }
});

test("winning operation replay remains idempotent after database restart", () => {
  const folder = mkdtempSync(join(tmpdir(), "edgecare-replay-"));
  const path = join(folder, "db.sqlite");
  try {
    const first = new DemoRepository(path, now);
    first.create(record); first.create(record.referral_id, record.commitment_hash);
    first.spend(record.referral_id, record.commitment_hash, "operation-one");
    const accepted = first.read(record.referral_id); first.close();
    const second = new DemoRepository(path, now);
    try {
      second.spend(record.referral_id, record.commitment_hash, "operation-one");
      assert.deepEqual(second.read(record.referral_id), accepted);
      assert.throws(() => second.spend(record.referral_id, record.commitment_hash, "operation-two"), /already spent/);
      assert.throws(() => second.spend(record.referral_id, "f".repeat(64), "operation-one"), /does not match/);
      second.create(record.referral_id, record.commitment_hash);
    } finally { second.close(); }
  } finally { rmSync(folder, { recursive: true, force: true }); }
});

test("separate database processes accept one winner and replay the same winning operation", async () => {
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const { fileURLToPath } = await import("node:url");
  const run = promisify(execFile);
  const folder = mkdtempSync(join(tmpdir(), "edgecare-concurrent-"));
  const path = join(folder, "db.sqlite");
  const worker = fileURLToPath(new URL("./support/registry-worker.ts", import.meta.url));
  const id = "88888888-8888-4888-8888-888888888888";
  const hash = "a".repeat(64);
  const invoke = (operation: string) => run(process.execPath, ["--import", "tsx", worker, path, id, hash, operation]);
  try {
    const setup = new DemoRepository(path, now); setup.close();
    const outcomes = await Promise.all([invoke("operation-a"), invoke("operation-b")]);
    assert.deepEqual(outcomes.map(result => result.stdout).sort(), ["accepted", "conflict"]);
    const winner = outcomes[0]!.stdout === "accepted" ? "operation-a" : "operation-b";
    const replays = await Promise.all([invoke(winner), invoke(winner)]);
    assert.deepEqual(replays.map(result => result.stdout), ["accepted", "accepted"]);
    const reopened = new DemoRepository(path, now);
    try { assert.equal(reopened.read(id)?.spent, true); } finally { reopened.close(); }
  } finally { rmSync(folder, { recursive: true, force: true }); }
});
