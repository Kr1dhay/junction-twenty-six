# Doctor verification

Run the `EdgeCareDoctor` target generated from root `project.yml`, or use the root Apple demo launcher. The app lists anonymous referrals, looks up and caches a full referral ID, and collects the patient's four-digit code and fresh signature. Shared core code decrypts the enrollment, matches the signature, checks the commitment and spends once. Secrets clear after submission, navigation, backgrounding, or two minutes of inactivity.

The result distinguishes local-device verification, shared-registry confirmation, provisional offline spending, and conflicts discovered during synchronization. The referral list refreshes every eight seconds while active. Offline verification requires an enrollment and commitment previously cached on that doctor device. The toolbar can simulate offline; reconnecting reconciles pending spends, with first accepted use winning.

`EDGECARE_MODE=local` is network-free and seeds synthetic fixtures; use the clearly labelled sample signature with code `1234` only for those synthetic records. Standalone local registries on different apps/devices do not share state. `EDGECARE_MODE=connected` uses the one backend at `EDGECARE_BASE_URL` with `EDGECARE_CLINICIAN_TOKEN` (legacy `EDGECARE_API_TOKEN` accepted) and optional `EDGECARE_ISSUER_TOKEN`. This is an explicitly labelled HTTP demo registry, not a Solana devnet deployment.

## Physical iPhone connection

Simulator launch settings do not carry over to Xcode or an iPhone. Before the
first Run, set the local `EdgeCareDoctor` scheme's Run → Arguments → Environment
Variables to `EDGECARE_MODE=connected`, the hosted HTTPS `EDGECARE_BASE_URL`, and
the `EDGECARE_CLINICIAN_TOKEN` from your private `edgecare-device.json`. Keep
credentials out of committed/shared schemes; never use provider API keys here.
An iPhone cannot reach the Mac through `127.0.0.1`.

After a successful connected startup, the doctor app saves only the HTTPS origin
and clinician credential in a device-only, unlocked-only Keychain item. Home
Screen launches then reuse that connection without Xcode. Patient codes,
signatures, issuer credentials and provider keys are not stored in this item.
Explicit launch settings always win in full, so a new host never inherits an old
credential; `EDGECARE_MODE=local` forces a network-free run. Unprovisioned apps
still default to local mode. Kiosk and patient defaults are unchanged.

The header should say **Shared-backend demo**, not **Local demo · this device
only**. Signature/code matching happens locally against clinician-authorized
envelopes downloaded from the backend. A local-only phone cannot find a referral
created on another device. Four-digit code fields dismiss the keyboard when
complete; this also applies when confirming a new code.

After the patient is verified, **Start consultation with notes** opens a live, two-way translated consultation (connected mode only). Speech is streamed to ElevenLabs Scribe v3 Live; the detected language decides who spoke; each sentence is translated and spoken aloud in the other language. Gemini Live records in parallel as an independent transcript with running key points. At the end, notes are drafted into the CRM's structured fields plus meeting notes, and both participants review them: the patient in their own language (read aloud on request) and the clinician in English. Flags, corrections, edits, and disputes clear both confirmations. Only when both confirm is the consultation saved to the CRM as an append-only record on the referral (queued encrypted on the phone if the connection drops). No audio is stored. See `API.md` → Doctor consultation.

Matching is an experimental demo aid, not a validated biometric or official care authorization. See `API.md` for protocol/security limits. The Linux implementation host had no Xcode/Apple SDK; native compilation and actual device behavior remain to be checked on a Mac.
