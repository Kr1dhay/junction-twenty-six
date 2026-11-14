import test from "node:test";
import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { Pool } from "@neondatabase/serverless";
import { PostgresRepository } from "../src/server/postgres-repository";
import { deletedID, OwnershipError } from "../src/server/profile-deletion";
import { syntheticProfile, consultationFor } from "./support/profile-fixtures";

const url = process.env.EDGECARE_TEST_DATABASE_URL;
test("hosted erasure removes related data, serializes concurrent writes and persists replay protection", { skip: !url }, async () => {
  const a = new PostgresRepository(url!, () => new Date("2033-03-10T06:00:00Z"));
  const b = new PostgresRepository(url!, () => new Date("2033-03-10T06:00:00Z"));
  const own = syntheticProfile(), other = syntheticProfile(), pending = syntheticProfile();
  const id = own.record.referral_id, ids = [id, other.record.referral_id, pending.record.referral_id];
  const visit = consultationFor(id);
  try {
    await Promise.all([a.create(own.record), b.create(other.record)]);
    await a.create(id, own.record.commitment_hash);
    await a.createConsultation(visit);
    const slot = (await a.appointmentSlots())[0]!;
    await a.bookAppointment(id, slot.slot_id, randomUUID());
    await assert.rejects(a.deleteProfile(id, randomBytes(32).toString("base64")), OwnershipError);
    assert.ok(await a.get(id)); assert.equal((await a.listConsultations(id)).length, 1);
    const visitRace = consultationFor(id);
    const race = await Promise.allSettled([
      a.deleteProfile(id, own.key), b.createConsultation(visitRace),
      b.update(own.record, { ...own.record, free_text_summary: "Concurrent update" }),
      b.spend(id, own.record.commitment_hash, randomUUID()),
      b.bookAppointment(id, slot.slot_id, randomUUID()),
    ]);
    assert.equal(race[0]!.status, "fulfilled");
    const reopened = new PostgresRepository(url!);
    assert.equal(await reopened.verificationEnvelope(id), undefined);
    assert.equal(await reopened.get(id), undefined); assert.equal(await reopened.read(id), undefined);
    assert.equal(await reopened.appointmentFor(id), undefined); assert.deepEqual(await reopened.listConsultations(id), []);
    assert.ok((await a.appointmentSlots()).some(item => item.slot_id === slot.slot_id));
    assert.ok(await reopened.get(other.record.referral_id));
    await reopened.deleteProfile(id, own.key);
    await assert.rejects(reopened.create(own.record), /deleted/);
    await assert.rejects(reopened.create(id, own.record.commitment_hash), /deleted/);
    await assert.rejects(reopened.createConsultation(visit), /not found/);
    // If deletion wins before either half of enrollment, neither upload can resurrect it.
    await a.deleteProfile(pending.record.referral_id, pending.key);
    const replay = await Promise.allSettled([b.create(pending.record), b.create(pending.record.referral_id, pending.record.commitment_hash)]);
    assert.ok(replay.every(result => result.status === "rejected"));
    const pool = new Pool({ connectionString: url! });
    try {
      assert.deepEqual((await pool.query("SELECT * FROM edgecare_demo_deleted_referrals WHERE id_hash = $1", [deletedID(id)])).rows, [{ id_hash: deletedID(id) }]);
      for (const table of ["edgecare_demo_appointments", "edgecare_demo_consultations"]) {
        assert.equal((await pool.query(`SELECT COUNT(*)::int AS n FROM ${table} WHERE referral_id = $1`, [id])).rows[0].n, 0);
      }
    } finally { await pool.end(); }
  } finally {
    const pool = new Pool({ connectionString: url! });
    try {
      for (const table of ["edgecare_demo_consultations", "edgecare_demo_appointments"]) await pool.query(`DELETE FROM ${table} WHERE referral_id = ANY($1::text[])`, [ids]);
      for (const table of ["edgecare_demo_referrals", "edgecare_demo_commitments"]) await pool.query(`DELETE FROM ${table} WHERE id = ANY($1::text[])`, [ids]);
      await pool.query("DELETE FROM edgecare_demo_deleted_referrals WHERE id_hash = ANY($1::text[])", [ids.map(deletedID)]);
    } finally { await pool.end(); }
  }
});
