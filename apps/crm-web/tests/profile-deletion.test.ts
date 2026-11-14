import test from "node:test";
import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import Database from "better-sqlite3";
import { DemoRepository, DeletedError } from "../src/server/repository";
import { OwnershipError, deletedID } from "../src/server/profile-deletion";
import { DELETE, GET, PATCH } from "../src/app/referrals/[id]/route";
import { POST } from "../src/app/referrals/route";
import { PUT } from "../src/app/demo/commitments/[id]/route";

import { syntheticProfile, consultationFor } from "./support/profile-fixtures";

test("erasure is atomic, preserves unrelated patients, cancels slots, survives reopen and blocks offline replay", () => {
  const directory = mkdtempSync(join(tmpdir(), "edgecare-erasure-")), path = join(directory, "db.sqlite");
  const a = new DemoRepository(path, () => new Date("2033-02-01T06:00:00Z"));
  const own = syntheticProfile(), other = syntheticProfile(), id = own.record.referral_id;
  const visit = consultationFor(id);
  try {
    for (const item of [own, other]) { a.create(item.record); a.create(item.record.referral_id, item.record.commitment_hash); }
    a.spend(id, own.record.commitment_hash, randomUUID());
    a.createConsultation(visit);
    const slot = a.appointmentSlots()[0]!;
    const booking = a.bookAppointment(id, slot.slot_id, randomUUID());
    assert.throws(() => a.deleteProfile(id, randomBytes(32).toString("base64")), OwnershipError);
    assert.ok(a.verificationEnvelope(id)); assert.equal(a.listConsultations(id).length, 1);
    assert.ok(a.appointmentFor(id)); assert.ok(a.read(id));
    a.deleteProfile(id, own.key);
    assert.equal(a.get(id), undefined); assert.equal(a.verificationEnvelope(id), undefined);
    assert.equal(a.read(id), undefined); assert.deepEqual(a.listConsultations(id), []); assert.equal(a.appointmentFor(id), undefined);
    assert.ok(a.appointmentSlots().some(item => item.slot_id === slot.slot_id));
    assert.ok(a.get(other.record.referral_id));
    const b = new DemoRepository(path);
    try {
      b.deleteProfile(id, own.key); // Response-loss retry is harmless.
      assert.throws(() => b.create(own.record), DeletedError);
      assert.throws(() => b.create(id, own.record.commitment_hash), DeletedError);
      assert.throws(() => b.update(own.record, own.record), /not found/);
      assert.throws(() => b.createConsultation(visit), /not found/);
      assert.throws(() => b.bookAppointment(id, slot.slot_id, booking.appointment_id), /not found/);
      assert.throws(() => b.cancelAppointment(id, booking.appointment_id), /not found/);
    } finally { b.close(); }
    const raw = new Database(path);
    try {
      assert.deepEqual(raw.prepare("SELECT * FROM deleted_referrals").all(), [{ id_hash: deletedID(id) }]);
      for (const table of ["consultations", "appointments"]) assert.equal((raw.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE referral_id = ?`).get(id) as { n: number }).n, 0);
    } finally { raw.close(); }
  } finally { a.close(); rmSync(directory, { recursive: true, force: true }); }
});

test("expired and never-uploaded profiles can be erased and cannot be enrolled afterward", () => {
  const repo = new DemoRepository(":memory:", () => new Date("2035-01-01T00:00:00Z")), own = syntheticProfile();
  try {
    repo.create(own.record); repo.deleteProfile(own.record.referral_id, own.key);
    const pending = syntheticProfile(); repo.deleteProfile(pending.record.referral_id, pending.key);
    assert.throws(() => repo.create(pending.record), DeletedError);
    assert.throws(() => repo.create(pending.record.referral_id, pending.record.commitment_hash), DeletedError);
  } finally { repo.close(); }
});

test("patient deletion requires device access AND the unlocked key; input and origin are guarded", async () => {
  const directory = mkdtempSync(join(tmpdir(), "edgecare-erasure-route-"));
  process.env.DEMO_MODE = "true"; process.env.CHAIN = "mock"; process.env.LLM = "ondevice";
  process.env.EDGECARE_DB_PATH = join(directory, "db.sqlite");
  process.env.EDGECARE_ISSUER_TOKEN = "erasure-test-issuer"; process.env.EDGECARE_CLINICIAN_TOKEN = "erasure-test-clinician";
  const own = syntheticProfile(), other = syntheticProfile(), id = own.record.referral_id;
  const context = { params: Promise.resolve({ id }) };
  const request = (body: unknown, token = "erasure-test-clinician", method = "DELETE", origin?: string) => new Request(`http://localhost/referrals/${id}`, {
    method, headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(origin ? { origin } : {}) },
    ...(method === "GET" ? {} : { body: JSON.stringify(body) }),
  });
  try {
    for (const item of [own, other]) assert.equal((await POST(request(item.record, "erasure-test-issuer", "POST"))).status, 201);
    const proof = { encryption_key: own.key };
    assert.equal((await DELETE(request(proof, ""), context)).status, 401);
    assert.equal((await DELETE(request(proof, "erasure-test-issuer"), context)).status, 401);
    assert.equal((await DELETE(request(proof, undefined, "DELETE", "https://untrusted.example"), context)).status, 403);
    assert.equal((await DELETE(request({ commitment_hash: own.record.commitment_hash }), context)).status, 400);
    assert.equal((await DELETE(request({ ...proof, passcode: "0123" }), context)).status, 400);
    assert.equal((await DELETE(request({ encryption_key: other.key }), context)).status, 403);
    assert.equal((await GET(request(undefined, undefined, "GET"), context)).status, 200);
    assert.equal((await DELETE(request(proof), context)).status, 200);
    assert.equal((await DELETE(request(proof), context)).status, 200);
    assert.equal((await GET(request(undefined, undefined, "GET"), context)).status, 404);
    assert.equal((await POST(request(own.record, "erasure-test-issuer", "POST"))).status, 410);
    assert.equal((await PUT(request({ commitment_hash: own.record.commitment_hash }, "erasure-test-issuer", "PUT"), context)).status, 410);
    assert.equal((await PATCH(request({ expected: own.record, record: own.record }, "erasure-test-issuer", "PATCH"), context)).status, 404);
    assert.equal((await GET(request(undefined, undefined, "GET"), { params: Promise.resolve({ id: other.record.referral_id }) })).status, 200);
    assert.equal((await DELETE(request(proof), { params: Promise.resolve({ id: "INVALID" }) })).status, 400);
    assert.equal((await DELETE(request({ encryption_key: "x".repeat(2048) }), context)).status, 400);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
