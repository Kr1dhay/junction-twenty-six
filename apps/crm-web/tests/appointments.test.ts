import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { demoReferrals } from "@edgecare/shared-types/fixtures";
import { offeredSlots } from "../src/server/appointments";
import { DemoRepository } from "../src/server/repository";

test("demo slots keep Helsinki clinic hours across daylight saving, weekdays and minimum notice", () => {
  for (const [instant, expected] of [
    ["2026-11-14T12:00:00Z", "2026-11-16T07:00:00.000Z"],
    ["2027-03-26T15:00:00Z", "2027-03-29T06:00:00.000Z"],
    ["2027-10-29T15:00:00Z", "2027-11-01T07:00:00.000Z"],
    ["2026-11-16T07:31:00Z", "2026-11-16T09:00:00.000Z"],
  ]) {
    const now = new Date(instant!), slots = offeredSlots(now);
    assert.equal(slots[0]?.starts_at, expected);
    assert.equal(new Set(slots.map(slot => slot.slot_id)).size, slots.length);
    for (const slot of slots) {
      assert.ok(new Date(slot.starts_at).getTime() >= now.getTime() + 30 * 60_000);
      assert.equal(new Date(slot.ends_at).getTime() - new Date(slot.starts_at).getTime(), 30 * 60_000);
      assert.ok(![0, 6].includes(new Date(slot.starts_at).getUTCDay()));
      assert.equal(slot.time_zone, "Europe/Helsinki");
      assert.equal(slot.demo, true);
    }
  }
});

test("shared bookings persist, reserve one slot and one referral, retry exactly and release on cancellation", () => {
  const folder = mkdtempSync(join(tmpdir(), "edgecare-booking-"));
  let instant = new Date("2026-11-14T12:00:00Z");
  const first = new DemoRepository(join(folder, "db.sqlite"), () => instant);
  const second = new DemoRepository(join(folder, "db.sqlite"), () => instant);
  const record = { ...demoReferrals[0]!, referral_id: randomUUID(), expires_at: "2027-01-01T00:00:00Z" };
  const other = { ...record, referral_id: randomUUID() };
  try {
    first.create(record); first.create(other); first.create(record.referral_id, record.commitment_hash);
    const [slot, next] = first.appointmentSlots();
    const operation = randomUUID();
    const booking = first.bookAppointment(record.referral_id, slot!.slot_id, operation);
    assert.deepEqual(second.appointmentFor(record.referral_id), booking);
    assert.ok(!second.appointmentSlots().some(item => item.slot_id === slot!.slot_id));
    assert.deepEqual(second.bookAppointment(record.referral_id, slot!.slot_id, operation), booking);
    assert.throws(() => second.bookAppointment(other.referral_id, slot!.slot_id, randomUUID()), /taken/);
    assert.throws(() => second.bookAppointment(record.referral_id, next!.slot_id, randomUUID()), /already has/);
    assert.throws(() => second.bookAppointment(other.referral_id, next!.slot_id, operation), /already used/);
    assert.throws(() => second.bookAppointment(randomUUID(), next!.slot_id, randomUUID()), /not found/);
    assert.throws(() => second.bookAppointment(other.referral_id, "invented-time", randomUUID()), /no longer/);
    assert.throws(() => second.cancelAppointment(other.referral_id, operation), /not found/);
    const cancelled = first.cancelAppointment(record.referral_id, operation);
    assert.equal(cancelled.status, "cancelled");
    assert.deepEqual(second.cancelAppointment(record.referral_id, operation), cancelled);
    assert.deepEqual(second.bookAppointment(record.referral_id, slot!.slot_id, operation), cancelled);
    assert.equal(second.appointmentFor(record.referral_id), undefined);
    assert.ok(second.appointmentSlots().some(item => item.slot_id === slot!.slot_id));
    second.bookAppointment(other.referral_id, slot!.slot_id, randomUUID());
    const another = first.bookAppointment(record.referral_id, next!.slot_id, randomUUID());
    const registry = first.read(record.referral_id);
    instant = new Date(new Date(another.starts_at).getTime() + 31 * 60_000);
    assert.equal(second.appointmentFor(record.referral_id), undefined);
    first.bookAppointment(record.referral_id, first.appointmentSlots()[0]!.slot_id, randomUUID());
    assert.deepEqual(first.read(record.referral_id), registry);
    assert.equal(first.get(record.referral_id)?.status, "open");
    instant = new Date("2027-01-02T00:00:00Z");
    assert.throws(() => first.bookAppointment(record.referral_id, first.appointmentSlots()[0]!.slot_id, randomUUID()), /expired/);
  } finally { first.close(); second.close(); rmSync(folder, { recursive: true, force: true }); }
});

test("a slot cannot extend beyond the referral expiry", () => {
  const store = new DemoRepository(":memory:", () => new Date("2026-11-14T12:00:00Z"));
  try {
    const slot = store.appointmentSlots()[0]!;
    const record = { ...demoReferrals[0]!, expires_at: new Date(new Date(slot.ends_at).getTime() - 1).toISOString() };
    store.create(record);
    assert.throws(() => store.bookAppointment(record.referral_id, slot.slot_id, randomUUID()), /expired/);
  } finally { store.close(); }
});
