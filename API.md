# Edge-Care integration contract — v1

The four apps share one REST backend and a commitment-registry boundary. Apps do not call one another. Next.js hosts REST routes and SQLite; Swift apps use `EdgeCareCore`, and the CRM/backend use `@edgecare/shared-types`.

## Transport and privacy

JSON uses snake_case, canonical lowercase UUIDs, UTC ISO-8601 timestamps, padded base64 and lowercase SHA-256 hex. `packages/shared-types/schema/referral.schema.json` describes enrollment. Swift and TypeScript decode the same fixtures.

`ReferralRecord` is the enrollment payload. `CRMReferral` is an allowlist projection excluding source, kiosk ID, salt, commitment hash, encrypted signature and encrypted private triage. English display summaries are intentionally clinician-readable. No passcode or plaintext signature is uploaded. Raw images stay on-device; voice audio is sent to an external provider only through the explicitly consented voice endpoint.

All referral/voice responses use `Cache-Control: no-store`. The server requires `DEMO_MODE=true`, `CHAIN=mock`, `LLM=ondevice` for the synthetic demo registry. This guard does not enable external voice by itself: voice also requires separate provider configuration and per-request consent.

## Access

Browser clinicians create an eight-hour HttpOnly/SameSite=Strict demo session via `POST /demo/session`, and clear it via `DELETE /demo/session`. If `EDGECARE_CLINICIAN_TOKEN` is configured, session creation requires that bearer token. Unconfigured one-click sessions are loopback-only.

Native clients use `Authorization: Bearer TOKEN`: `EDGECARE_ISSUER_TOKEN` for enrollment/creation/voice and `EDGECARE_CLINICIAN_TOKEN` for reading verification envelopes and spending. Explicit synthetic loopback requests without browser Origin/Fetch headers may omit an unconfigured token. Cross-origin requests are rejected. These controls do not provision or verify real clinicians.

## Referral and registry endpoints

| Method/path | Actor | Result |
| --- | --- | --- |
| `POST /referrals` | Issuer | Validated enrollment: 201 create, 200 identical retry, 409 different content for an existing ID. Initial status must be `open`. |
| `GET /referrals` | Clinician | `{ referrals: CRMReferral[] }`, newest first; filters/sorting run in the CRM. |
| `GET /referrals/:id` | Clinician | Allowlisted detail, or 404. |
| `DELETE /referrals/:id` | Patient using authorized device | Body `{ encryption_key }` after local code/signature login; authenticates the sealed clinical payload, then atomically deletes profile, consultations, appointments and commitment. 200 on success/retry, 403 invalid ownership proof. See [patient deletion](docs/patient-deletion.md). |
| `GET /referrals/:id/verification` | Clinician | Encrypted enrollment envelope for on-device decryption, or 404. |
| `PUT /demo/commitments/:id` | Issuer | Body `{ commitment_hash }`; creates a shared synthetic commitment. Same-hash retry succeeds, conflicting hash returns 409. |
| `GET /demo/commitments/:id` | Clinician | `{ commitment_hash, spent, created_slot, spent_slot }`, or 404. |
| `POST /demo/commitments/:id/spend` | Clinician | Body `{ commitment_hash, operation_id }`; atomically consumes the commitment. Same operation retry succeeds; a competing spend returns 409. |
| `GET /health` | Development | Readiness and synthetic demo mode. |

Errors use `{ error: string }`. Invalid input returns 400, missing authorization 401, forbidden origins 403, missing records 404 and conflicts 409. Enrollment/commitment replay for a deleted profile returns 410, so a queued offline upload cannot recreate it. `operation_id` is a stable UUID persisted before sending. Legacy clients may omit it, but then cannot distinguish a lost successful response from another spender.

SQLite stores the shared mock registry and reconciles referral status on read. The CRM polls every two seconds; a spend becomes visible without a manual refresh. A registry spend outranks expiry when deriving final display status.

## Conversation and English profile

`POST /demo/voice/turn` accepts issuer authorization and JSON:

```json
{
  "consent": true,
  "audio_base64": "...",
  "audio_mime_type": "audio/mp4",
  "profile": {
    "concern_english": "",
    "symptoms_english": [],
    "duration_english": "",
    "additional_context_english": ""
  },
  "history": [{ "role": "assistant", "text": "How can I help?" }]
}
```

A typed turn sends `text` instead of audio. Audio recognition omits a language hint so ElevenLabs detects the spoken language; the response reports `detected_language`. The conversation adapter merges corrections into the supplied English profile and generates a reply in that language. ElevenLabs synthesizes the reply using the configured language-specific voice or default multilingual voice.

Responses contain `transcript`, `detected_language`, `reply`, `profile`, `audio_base64`, `audio_mime_type`, `speech_available` and `speech_error`. If synthesis fails after a valid text/profile turn, the response preserves those results and explicitly marks speech unavailable. Missing credentials or failed recognition/conversation return an error instead of fabricated results. `POST /demo/profile/normalize` provides text-to-English profile normalization without synthesized speech. See [voice setup](docs/voice-intake.md) for configuration and limits.

The voice proxy does not persist audio, transcript or conversation state. The caller owns the current session. On enrollment, the English profile is included in encrypted private triage and its English summary is projected to the clinician. Original-language notes and patient-language guidance remain separate from the canonical profile. The structured form uses an English catalog and works without a translation service.

## Doctor consultation (transcribed, translated, dual-confirmed)

All endpoints require clinician authorization (`EDGECARE_CLINICIAN_TOKEN` bearer or a browser session), `EDGECARE_CLOUD_VOICE=true`, and `"consent": true`. Provider keys never leave the server. Because the hosted backend cannot proxy WebSockets, the device opens the realtime transcription socket directly using a short-lived credential.

| Endpoint | Purpose |
| --- | --- |
| `POST /demo/consultations/session` | `{consent, referral_id, doctor_language, patient_language}` → `{scribe: {token, model, url}, expires_at}`. `scribe` is an ElevenLabs single-use realtime token (15 min); the device requests a fresh one before it expires. |
| `POST /demo/consultations/translate` | `{consent, text, source_language, target_language, speaker, synthesize}` → `{translated_text, source_language, target_language, audio_base64, audio_mime_type, speech_available, speech_error}`. Literal translation through the configured Gemini/Runware text model, then ElevenLabs TTS in the target language. A TTS failure keeps the text. |
| `POST /demo/consultations/speak` | `{consent, text, language}` → speech only. Reads confirmed text (for example the patient-language summary) aloud without translating it. |
| `POST /demo/consultations/notes` | `{consent, doctor_language, patient_language, transcript[], clinician_edits?}` → `{structured, clinical_summary, patient_language_summary, meeting_notes, meeting_notes_patient_language, discrepancies[]}`. Drafted from the transcript text by the configured Gemini/Runware text model, for translated and same-language visits alike. `meeting_notes` (and its patient-language copy) holds 3–8 `- ` bullet key points, never a turn-by-turn transcript. Corrections override machine translations. `clinician_assessment` and `plan` contain only what the clinician said. Legacy `live_transcript`/`live_key_points` fields from older app builds are accepted and ignored. |
| `POST /referrals/:id/consultations` | Stores a `ConsultationRecord` (see `consultationSchema` in `packages/shared-types`). It is rejected with 400 unless both `confirmation.patient_confirmed_at` and `confirmation.doctor_confirmed_at` are present and follow `ended_at`. The health record keeps the confirmed summary and key points only: `transcript` is stored empty (any segments sent by older app builds are dropped). Append-only and idempotent on `consultation_id` (201 created, 200 identical retry, 409 different content, 404 unknown referral). It never modifies the referral. |
| `GET /referrals/:id/consultations` | `{consultations: CRMConsultation[]}`, newest first, through an allowlist projection. |

Realtime socket opened by the device:

- ElevenLabs Scribe: `wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=…&token=…&audio_format=pcm_16000&commit_strategy=vad&include_timestamps=true&include_language_detection=true` plus, for two-language visits, `multilang_mode=true` (Scribe v3 Live) and no language hint, because `language_code`/`secondary_languages` make detection sticky across utterances; same-language visits pass `language_code=<language>`. Each committed segment's detected language decides the speaker (the patient's language means patient → clinician, the clinician's means clinician → patient); if Scribe reports no language or a third one, an on-device text check limited to the two languages decides, and otherwise the clinician's speaker switch does. Translated speech waits while someone is mid-sentence so their words are never cut off.

No audio is stored by the server or the device. The microphone is gated while translated speech plays. A confirmed record is written to an encrypted on-device outbox before upload, and is replayed by `sync` if the connection drops.

## Commitment and encryption

Version 1 preimage: 32 raw SHA-256 bytes of canonical enrolled signature-template data, four ASCII PIN bytes, 36 UTF-8 lowercase UUID characters, then 16 random salt bytes. Hash with SHA-256. Fuzzy verification recomputes from the **enrolled** template, never the fresh drawing's hash.

HKDF-SHA256 derives a 32-byte key from the PIN, salt and UTF-8 info `edgecare.referral.v1`. AES-GCM uses CryptoKit combined nonce (12 bytes), ciphertext and tag (16 bytes), base64 encoded. Runtime enrollment generates fresh salts/nonces. Fixture PIN `1234` and fixed vectors are exclusively synthetic test data.

Native wallet/outbox files have an additional AES-GCM encryption layer using a random Keychain key. No PIN is stored. A four-digit PIN is still vulnerable to offline guessing, and signature matching is unvalidated demonstration logic.

## Offline and settlement

Local mode constructs only local adapters and makes no network calls. Each device has its own registry. Connected-demo mode uses the shared HTTP backend and queues while offline. Enrollment sync creates the registry commitment, posts the encrypted record, then removes the durable operation. Identical retries are safe.

Doctor offline verification requires a previously cached enrollment and commitment. Signature/PIN checks can succeed locally, but the resulting use is provisional until the shared registry accepts its stable spend operation. The first accepted operation wins; a competing operation becomes a visible conflict. Unknown records cannot be retrieved offline. Expired referrals are rejected by the verification client.

## Real Solana boundary

The Anchor program creates a PDA from `b"commitment"` and UUID bytes, storing hash, authorized verifier and spend state. `create_commitment` requires an issuer/payer signature; `spend_commitment` requires the stored verifier and rejects double use. It trusts off-chain clinical verification and does not verify biometrics.

`scripts/registry.ts` builds/signs the program instructions against an explicitly configured deployment. Native `DevnetChainClient` remains unavailable until native signing is configured; the connected-demo path uses HTTP. No automatic devnet fallback, deployment or funded wallet is included. See [registry setup](programs/edgecare-registry/README.md).
