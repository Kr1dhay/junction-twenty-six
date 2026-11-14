import type { ReferralRecord } from "@edgecare/shared-types";

export interface AppointmentSlot {
  slot_id: string;
  starts_at: string;
  ends_at: string;
  time_zone: "Europe/Helsinki";
  location: "Edge-Care demo clinic";
  service: "Clinician review";
  demo: true;
}
export interface Appointment extends AppointmentSlot {
  appointment_id: string;
  referral_id: string;
  created_at: string;
  status: "booked" | "cancelled" | "completed";
}

const localDate = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Europe/Helsinki", year: "numeric", month: "2-digit", day: "2-digit",
  hour: "2-digit", minute: "2-digit", hourCycle: "h23",
});
function parts(date: Date) {
  const values = Object.fromEntries(localDate.formatToParts(date).map(part => [part.type, part.value]));
  return { year: Number(values.year), month: Number(values.month), day: Number(values.day), hour: Number(values.hour), minute: Number(values.minute) };
}
function helsinkiTime(year: number, month: number, day: number, hour: number) {
  const local = Date.UTC(year, month - 1, day, hour);
  let instant = local;
  // Resolve the actual Helsinki offset on this date, including daylight saving time.
  for (let i = 0; i < 3; i++) {
    const p = parts(new Date(instant));
    instant += local - Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute);
  }
  return new Date(instant);
}
export function offeredSlots(now: Date): AppointmentSlot[] {
  const today = parts(now);
  const slots: AppointmentSlot[] = [];
  for (let day = 0; day < 14; day++) {
    const date = new Date(Date.UTC(today.year, today.month - 1, today.day + day, 12));
    if ([0, 6].includes(date.getUTCDay())) continue;
    for (const hour of [9, 10, 11, 13, 14, 15]) {
      const start = helsinkiTime(date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate(), hour);
      if (start.getTime() < now.getTime() + 30 * 60_000) continue;
      const starts_at = start.toISOString();
      slots.push({ slot_id: `demo-${starts_at}`, starts_at, ends_at: new Date(start.getTime() + 30 * 60_000).toISOString(),
        time_zone: "Europe/Helsinki", location: "Edge-Care demo clinic", service: "Clinician review", demo: true });
    }
  }
  return slots;
}
export function eligibleSlot(record: ReferralRecord, slotID: string, now: Date): AppointmentSlot | undefined {
  if (new Date(record.expires_at) <= now) return;
  return offeredSlots(now).find(slot => slot.slot_id === slotID && new Date(slot.ends_at) <= new Date(record.expires_at));
}
export function makeAppointment(record: ReferralRecord, slot: AppointmentSlot, operationID: string, now: Date): Appointment {
  return { ...slot, appointment_id: operationID, referral_id: record.referral_id, created_at: now.toISOString(), status: "booked" };
}
