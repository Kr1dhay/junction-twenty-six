"use client";
import { useEffect, useState } from "react";
import type { Appointment } from "../server/appointments";
import { formatWait } from "../lib/waiting";

export function ReferralAppointment({ referralID, receivedAt }: { referralID: string; receivedAt?: string }) {
  const [result, setResult] = useState<{ id: string; appointment: Appointment | null; failed: boolean }>();
  useEffect(() => {
    let disposed = false;
    let timer: ReturnType<typeof setTimeout>;
    const controller = new AbortController();
    async function refresh() {
      try {
        const response = await fetch(`/referrals/${referralID}/appointment`, { cache: "no-store", signal: controller.signal });
        if (!response.ok) throw new Error("Appointment unavailable");
        const data = await response.json() as { appointment: Appointment | null };
        if (!disposed) setResult({ id: referralID, appointment: data.appointment, failed: false });
      } catch {
        if (!disposed) setResult(previous => ({ id: referralID, appointment: previous?.id === referralID ? previous.appointment : null, failed: true }));
      } finally {
        if (!disposed) timer = setTimeout(refresh, 5000);
      }
    }
    void refresh();
    return () => { disposed = true; clearTimeout(timer); controller.abort(); };
  }, [referralID]);
  const current = result?.id === referralID ? result : undefined;
  const booking = current?.appointment;
  const toBooking = booking && receivedAt ? Date.parse(booking.created_at) - Date.parse(receivedAt) : NaN;
  return <section className="detail-section" aria-label="Demo appointment">
    <h3>Demo appointment</h3>
    {!current ? <p role="status">Loading appointment…</p> : null}
    {current?.failed ? <p role="status">Appointment status unavailable. {booking ? "Showing the last confirmed booking." : "Retrying…"}</p> : null}
    {current && !current.failed && !booking ? <p>No upcoming demo appointment. Patients can book from the kiosk.</p> : null}
    {booking ? <>
      <p><strong><time dateTime={booking.starts_at}>{new Intl.DateTimeFormat("en-GB", { dateStyle: "full", timeStyle: "short", timeZone: booking.time_zone }).format(new Date(booking.starts_at))}</time></strong><br />Europe/Helsinki · 30 minutes</p>
      <p>{booking.service} · {booking.location}</p>
      {toBooking >= 0 ? <p>Booked {formatWait(toBooking)} after the referral was received.</p> : null}
      <p>Booking reference <code>{booking.appointment_id}</code></p>
      <small>Demo schedule. This does not reserve a real clinic appointment.</small>
    </> : null}
  </section>;
}
