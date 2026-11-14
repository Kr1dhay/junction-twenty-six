# Shared demo appointments

The kiosk welcome screen offers **Book an appointment** alongside creating and updating a referral. Existing patients enter their four-digit code and redraw their signature. Matching happens on the device; the booking API never receives these credentials. If several referrals match, the patient chooses one. After saving a new or updated referral, the handoff screen can open booking using that session's existing verification.

Patients choose a date and a 30-minute slot, explicitly confirm, and receive a demo booking reference. Reopening booking shows the existing upcoming appointment and offers cancellation with confirmation. Cancellation releases the slot. No appointment is queued or confirmed offline. Local-only kiosks show that shared booking requires connected mode.

This is a synthetic clinic schedule, not a real clinic integration. The screen says so before selection and confirmation. Booking does not spend a referral, reopen a used referral, change its expiry, or replace emergency advice.

## Schedule and storage

- Europe/Helsinki weekdays, at 09:00, 10:00, 11:00, 13:00, 14:00 and 15:00.
- Rolling 14-calendar-day window; at least 30 minutes' notice. Daylight saving follows Helsinki's actual offset.
- Slots must end before the chosen referral expires. Unexpired used referrals can also book.
- One upcoming appointment per referral and one booking per slot, enforced by database transactions and unique indexes.
- Local connected demos use persistent SQLite. Hosted demos use the existing Neon Postgres database with additive table creation; bookings survive instance restarts and deployments.
- Booking operation UUIDs are idempotent. A retry after cancellation returns the cancelled result instead of making another reservation. Cancelling an old booking cannot cancel a later booking.

The CRM's referral detail panel displays the upcoming booking, reference, clinic, date and Helsinki time. It refreshes every five seconds and labels failed refreshes instead of implying that no booking exists.

## API

All endpoints require the synthetic-demo backend configuration and existing same-origin/device authorization. Issuer devices may read and write. Clinician devices and CRM sessions may read, but cannot book or cancel.

| Method | Path | Body / response |
| --- | --- | --- |
| GET | `/appointments/slots` | `{slots, demo:true}` |
| GET | `/referrals/:id/appointment` | `{appointment: booking or null, demo:true}` |
| POST | `/referrals/:id/appointment` | `{slot_id, operation_id}`; returns the booking |
| DELETE | `/referrals/:id/appointment` | `{appointment_id}`; returns the cancelled booking |

Writes accept only bounded, strictly validated JSON. Missing records return 404; contention, expired referrals and unavailable slots return 409. Slot timestamps, duration and clinic metadata come from the server's schedule. No provider credentials or new environment variables are required.

## Mac update and verification

With the existing simulators booted and their apps installed:

```sh
git pull --ff-only
pnpm install --frozen-lockfile
python3 scripts/connect-hosted.py --config edgecare-device.json --rebuild
```

The launcher runs Swift tests, rebuilds and relaunches installed apps against the hosted backend. Test the welcome-screen lookup, new-referral handoff, selecting a date, explicit confirmation, reopening the booking, cancellation, a competing kiosk taking a slot, offline failure, language switching and idle reset. Check that the CRM shows the same booking and removal after cancellation.

Backend tests cover Helsinki daylight saving, minimum notice, expiry, persistence, idempotency, authorization and contention. `postgres-appointments.test.ts` additionally checks real cross-instance Neon races when explicitly supplied `EDGECARE_TEST_DATABASE_URL`, and deletes only its own synthetic rows. The browser integration checks booking visibility and cancellation through the CRM.

Swift syntax is checked on the Linux development host. Native typechecking, Swift tests and simulator interaction require the Mac toolchain and remain a separate verification step.

## Verification on 2026-11-14

- `pnpm check`: 49 passed, with two opt-in database tests skipped in the default run.
- Explicit real-Neon appointment test: passed; slot contention, referral contention, persistence, exact retries, cancellation and booking after an elapsed appointment were exercised. Its temporary rows were removed.
- `pnpm build`: passed, including the equity-action changes pulled from `main`.
- `EDGECARE_TEST_CHROME=/usr/bin/google-chrome pnpm test:browser`: all six passed, including the CRM appointment flow and the newly pulled equity-action screens.
- Changed Swift sources and appointment tests parsed successfully. Swift compilation and simulator checks have not run on this Linux host.
