import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { Pool } from "@neondatabase/serverless";
import { demoReferrals } from "@edgecare/shared-types/fixtures";
import { PostgresRepository } from "../src/server/postgres-repository";

// Explicit opt-in: a disposable synthetic row namespace, never real patient data.
const url = process.env.EDGECARE_TEST_DATABASE_URL;
test("hosted Postgres survives new instances and serializes enrollment, registry and consume races", { skip: !url }, async () => {
  const ids = Array.from({ length: 5 }, () => randomUUID());
  let instant = new Date("2026-11-14T12:00:00.000Z");
  const a = new PostgresRepository(url!, () => instant);
  const b = new PostgresRepository(url!, () => instant);
  const record = { ...demoReferrals[0]!, referral_id: ids[0]! };
  try {
    await Promise.all([a.ready(), b.ready()]);
    const enrollments = await Promise.all([a.create(record), b.create(record)]);
    assert.deepEqual(enrollments.map(r => r.created).sort(), [false, true]);
    await assert.rejects(a.create({ ...record, risk_score: 0 }), /different content/);
    await Promise.all([a.create(record.referral_id, record.commitment_hash), b.create(record.referral_id, record.commitment_hash)]);
    await assert.rejects(a.create(record.referral_id, "f".repeat(64)), /different content/);
    const spends = await Promise.allSettled([a.spend(record.referral_id, record.commitment_hash, "operation-a"), b.spend(record.referral_id, record.commitment_hash, "operation-b")]);
    assert.equal(spends.filter(r => r.status === "fulfilled").length, 1);
    assert.match(String((spends.find(r => r.status === "rejected") as PromiseRejectedResult).reason), /already spent/);
    const winner = spends[0]!.status === "fulfilled" ? "operation-a" : "operation-b";
    const before = await a.read(record.referral_id);
    instant = new Date("2031-01-01T00:00:00.000Z");
    const reopened = new PostgresRepository(url!, () => instant);
    await Promise.all([reopened.spend(record.referral_id, record.commitment_hash, winner), b.spend(record.referral_id, record.commitment_hash, winner)]);
    assert.deepEqual(await reopened.read(record.referral_id), before);
    assert.equal((await reopened.get(record.referral_id))?.status, "spent");
    await assert.rejects(reopened.spend(record.referral_id, "f".repeat(64), winner), /does not match/);
    await reopened.create(record.referral_id, record.commitment_hash);
    const crm = await reopened.get(record.referral_id);
    assert.equal(Object.hasOwn(crm!, "patient_name"), false);
    assert.deepEqual(await reopened.verificationEnvelope(record.referral_id), record);
    const updated = { ...record, free_text_summary: "Updated English clinical profile" };
    await a.update(record, updated);
    await b.update(record, updated);
    assert.deepEqual(await reopened.verificationEnvelope(record.referral_id), updated);
    assert.equal((await reopened.get(record.referral_id))?.status, "spent");
    assert.deepEqual(await reopened.read(record.referral_id), before);
    await assert.rejects(b.update(record, { ...record, free_text_summary: "Stale update" }), /changed/);
    await assert.rejects(b.update(updated, { ...updated, commitment_hash: "f".repeat(64) }), /identity/);
    const updates = await Promise.allSettled([
      a.update(updated, { ...updated, free_text_summary: "Concurrent edit A" }),
      b.update(updated, { ...updated, free_text_summary: "Concurrent edit B" }),
    ]);
    assert.equal(updates.filter(result => result.status === "fulfilled").length, 1);
    assert.equal(updates.filter(result => result.status === "rejected").length, 1);
    assert.equal((await reopened.get(record.referral_id))?.status, "spent");
    const expired = { ...record, referral_id: ids[1]! };
    await a.create(expired); await a.create(expired.referral_id, expired.commitment_hash);
    await assert.rejects(a.spend(expired.referral_id), /expired/);
    assert.equal((await a.get(expired.referral_id))?.status, "expired");
    await assert.rejects(a.spend(ids[4]!), /not found/);
    for (const id of ids.slice(2, 4)) {
      const conflicting = { ...record, referral_id: id };
      const race = await Promise.allSettled([a.create(conflicting), b.create(id, "f".repeat(64))]);
      assert.equal(race.filter(r => r.status === "fulfilled").length, 1);
      assert.match(String((race.find(r => r.status === "rejected") as PromiseRejectedResult).reason), /does not match/);
      const envelope = await a.verificationEnvelope(id);
      const account = await a.read(id);
      assert.equal(Boolean(envelope && account), false);
    }
  } finally {
    const pool = new Pool({ connectionString: url! });
    try {
      await pool.query("DELETE FROM edgecare_demo_referrals WHERE id = ANY($1::text[])", [ids]);
      await pool.query("DELETE FROM edgecare_demo_commitments WHERE id = ANY($1::text[])", [ids]);
    } finally { await pool.end(); }
  }
});

test("hosted Postgres stores consultations append-only and idempotently", { skip: !url }, async () => {
  const fixture = JSON.parse((await import("node:fs")).readFileSync("packages/shared-types/fixtures/consultation.json", "utf8"));
  const referral = { ...demoReferrals[0]!, referral_id: randomUUID() };
  const consultation = { ...fixture, consultation_id: randomUUID(), referral_id: referral.referral_id };
  const a = new PostgresRepository(url!), b = new PostgresRepository(url!);
  try {
    await a.create(referral);
    const results = await Promise.all([a.createConsultation(consultation), b.createConsultation(consultation)]);
    assert.deepEqual(results.map(r => r.created).sort(), [false, true]);
    await assert.rejects(a.createConsultation({ ...consultation, meeting_notes: "changed" }), /different content/);
    await assert.rejects(a.createConsultation({ ...consultation, consultation_id: randomUUID(), referral_id: randomUUID() }), /not found/);
    assert.deepEqual((await b.listConsultations(referral.referral_id)).map(c => c.consultation_id), [consultation.consultation_id]);
  } finally {
    const pool = new Pool({ connectionString: url! });
    await pool.query("DELETE FROM edgecare_demo_consultations WHERE referral_id = $1", [referral.referral_id]);
    await pool.query("DELETE FROM edgecare_demo_referrals WHERE id = $1", [referral.referral_id]);
    await pool.end();
  }
});
