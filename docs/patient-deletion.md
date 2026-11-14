# Patient profile deletion

In the patient iPhone app, open **My profile**, then sign in with the enrolled four-digit code and signature. This finds all matching profiles, including used and expired referrals. Confirm **Delete my profiles and history** to delete all profiles displayed in this login. Other patients' profiles remain intact. Signing out, leaving the screen, backgrounding the app, or five minutes elapsing clears the login; deletion itself also checks that the login is fresh.

Connected mode requires a working connection. For each profile, the backend atomically deletes its encrypted enrollment, clinician-readable profile, consultation records, all appointment records (releasing booked slots), and mock-registry commitment. The app clears its encrypted wallet, enrollment/spend/consultation queues, matching completed intake draft, and login state. Local mode deletes only this device's local-mode records and says so explicitly. No cloud-deletion success is shown for an offline/failed request. If deleting several profiles partially succeeds, the UI removes the successful ones and leaves the remaining ones available to retry.

The backend retains only a SHA-256 digest of the anonymous referral UUID to reject old enrollment/commitment uploads with HTTP 410. That digest contains no health data, signature, PIN, commitment or encryption key. A durable deletion intent prevents this device's sync queue from re-uploading the profile after a crash; an interrupted request can be retried after signing in again. It does not change another profile's queued enrollment.

## Authorization and limits

`DELETE /referrals/:id` requires clinician device authorization plus `{ "encryption_key": "<32 bytes in padded base64>" }`. The native core creates this in-memory capability only after matching the code **and** signature locally; the clinician's debug bypass is deliberately unavailable. The server independently authenticates the current sealed clinical payload with AES-GCM before deleting an existing profile. Neither the PIN nor signature is sent. The short-lived request key and transient plaintext must never be logged, sent to analytics, or persisted. An already absent profile can be retried and tombstoned without revealing any patient data. This continues the demonstration's existing PIN/signature security model; it is not production identity assurance.

Deletion removes active records from the shared application database. It does not erase previously downloaded copies on other devices, clinic exports, or the storage provider's historical backups. No backup-erasure or real Solana-chain deletion is claimed. The current native connected mode uses the HTTP mock registry.

## Verification and Mac update

Backend tests cover wrong proofs, origin/device authorization, strict bounded bodies, expired/unsent records, related-data removal, preservation of other patients, retry/restart behavior, and blocked replay. The opt-in Neon test additionally races deletion against consultation creation, profile updates, spending and booking to check that no dependent records survive. It removes only its own random test records.

Swift regressions cover login matching without a debug bypass, expired-profile deletion, local cleanup, offline/failure behavior, stale login rejection, encrypted-wallet migration, crash recovery, and unrelated queued uploads. Swift syntax can be checked on Linux, but these tests and SwiftUI builds require macOS/Xcode.

Pull `main` and rebuild the native apps on the Mac:

```sh
git pull --ff-only
pnpm install --frozen-lockfile
python3 scripts/connect-hosted.py --config edgecare-device.json --rebuild
```

A backend deployment alone does not update an already-installed iPhone app.
