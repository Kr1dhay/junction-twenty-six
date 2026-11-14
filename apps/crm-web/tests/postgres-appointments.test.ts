import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { Pool } from "@neondatabase/serverless";
import { demoReferrals } from "@edgecare/shared-types/fixtures";
import { PostgresRepository } from "../src/server/postgres-repository";

const url = process.env.EDGECARE_TEST_DATABASE_URL;
test("hosted booking races have one winner; retries survive new instances and cancellation releases the slot", { skip: !url }, async () => {
  const ids = [randomUUID(), randomUUID()];
  // A separate future schedule prevents this test from occupying current demo slots.
  let instant = new Date("2033-02-01T06:00:00Z");
  const a = new PostgresRepository(url!, () => instant), b = new PostgresRepository(url!, () => instant);
  const operations = [randomUUID(), randomUUID()];
  try {
    await Promise.all(ids.map(id => a.create({ ...demoReferrals[0]!, referral_id: id, expires_at: "2034-01-01T00:00:00Z" })));
    const [slot, next] = await a.appointmentSlots();
    const race = await Promise.allSettled(ids.map((id, i) => (i ? b : a).bookAppointment(id, slot!.slot_id, operations[i]!)));
    assert.equal(race.filter(result => result.status === "fulfilled").length, 1);
    const winner = race[0]!.status === "fulfilled" ? 0 : 1, loser = 1 - winner;
    const booking = (race[winner] as PromiseFulfilledResult<Awaited<ReturnType<typeof a.bookAppointment>>>).value;
    const reopened = new PostgresRepository(url!, () => instant);
    assert.deepEqual(await reopened.appointmentFor(ids[winner]!), booking);
    assert.deepEqual(await reopened.bookAppointment(ids[winner]!, slot!.slot_id, operations[winner]!), booking);
    assert.ok(!(await reopened.appointmentSlots()).some(item => item.slot_id === slot!.slot_id));
    await assert.rejects(a.bookAppointment(ids[winner]!, next!.slot_id, randomUUID()), /already has/);
    await assert.rejects(b.bookAppointment(ids[loser]!, next!.slot_id, operations[winner]!), /already used/);
    const cancelled = await a.cancelAppointment(ids[winner]!, booking.appointment_id);
    assert.equal(cancelled.status, "cancelled");
    assert.deepEqual(await b.cancelAppointment(ids[winner]!, booking.appointment_id), cancelled);
    assert.deepEqual(await b.bookAppointment(ids[winner]!, slot!.slot_id, operations[winner]!), cancelled);
    await b.bookAppointment(ids[loser]!, slot!.slot_id, randomUUID());
    const sameReferralRace = await Promise.allSettled([
      a.bookAppointment(ids[winner]!, next!.slot_id, randomUUID()),
      b.bookAppointment(ids[winner]!, (await b.appointmentSlots())[2]!.slot_id, randomUUID()),
    ]);
    assert.equal(sameReferralRace.filter(result => result.status === "fulfilled").length, 1);
    instant = new Date("2033-02-02T06:00:00Z");
    assert.equal(await a.appointmentFor(ids[winner]!), undefined);
    await a.bookAppointment(ids[winner]!, (await a.appointmentSlots())[0]!.slot_id, randomUUID());
    assert.equal((await a.get(ids[winner]!))?.status, "open");
  } finally {
    const pool = new Pool({ connectionString: url! });
    try {
      await pool.query("DELETE FROM edgecare_demo_appointments WHERE referral_id = ANY($1::text[])", [ids]);
      await pool.query("DELETE FROM edgecare_demo_referrals WHERE id = ANY($1::text[])", [ids]);
    } finally { await pool.end(); }
  }
});
