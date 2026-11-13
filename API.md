# Edge-Care integration contract — v1

All four apps share one REST backend and one registry program. Apps never call one another. The local backend is hosted alongside the CRM using Next.js route handlers and SQLite. The Swift apps use `EdgeCareCore`; the CRM/backend use `@edgecare/shared-types`.

## Transport and records

JSON uses snake_case, lowercase canonical UUIDs, UTC ISO-8601 timestamps, standard padded base64 and lowercase SHA-256 hex. `packages/shared-types/schema/referral.schema.json` is the wire schema; the same fixture is decoded in TypeScript and Swift tests. Changing the protocol requires updating both models and those tests.

`ReferralRecord` is the enrollment payload. `CRMReferral` is an explicit allowlist projection: it excludes `source`, `kiosk_id`, salt, commitment hash, encrypted signature and encrypted triage. This resolves the brief's source field versus source-indistinguishable CRM requirement. Display summaries and evidence descriptions are intentionally readable by the clinician; full conversation/evidence and signature templates belong only in encrypted fields. Never upload raw images, names, contacts, passcodes or plaintext signatures.

## REST endpoints

| Method/path | Actor | Result |
| --- | --- | --- |
| `POST /referrals` | Kiosk, patient | Validated enrollment; 201 on create, 200 on identical retry, 409 if an ID already has different content. New status must be `open`. |
| `GET /referrals` | CRM, doctor | `{ referrals: CRMReferral[] }`, newest first. Status/risk/specialty/date filtering is local in the scaffold. |
| `GET /referrals/:id` | CRM, doctor | `CRMReferral`, or 404. |
| `GET /referrals/:id/verification` | Doctor verifier | Enrollment envelope for on-device decryption, or 404. Must be restricted to clinicians before any real deployment. |
| `GET /health` | Development | Backend readiness and demo mode. |

Errors are `{ error: string }`; malformed input returns 400. All referral responses use `Cache-Control: no-store`. The scaffold serves **synthetic local demo data only**, listens on loopback by default, and fails closed unless `DEMO_MODE=true`, `CHAIN=mock`, `LLM=ondevice`. Clinician authentication, provisioning and a production repository are explicit follow-up work.

## Registry boundary

`create_commitment(referral_id: [u8;16], hash: [u8;32], verifier: Pubkey)` creates a PDA seeded with `b"commitment"` and UUID bytes. The payer/issuer signs; the chosen verifier is stored. `spend_commitment(referral_id)` requires that verifier's signature and rejects repeated spends. The verifier is a trusted clinical authority: on-chain code enforces authorization and single use, not biometric verification. Program ID is a local scaffold placeholder; generate keys and synchronize IDs before deployment.

Swift `ChainClient` has create/read/spend operations; the persistent mock has the same lifecycle. `DevnetChainClient` deliberately throws `notConfigured` until signing, RPC and IDL wiring exist. No silent mock fallback in devnet mode. SQLite has a matching local registry table and reconciles CRM status on each read. There is no public HTTP spend shortcut in this scaffold.

## Commitment and encryption

Version 1 preimage: 32 raw SHA-256 bytes of canonical template data, then four ASCII passcode bytes, then 36 UTF-8 lowercase UUID characters, then 16 random salt bytes. Hash with SHA-256. Use the **enrolled** template hash after a fuzzy match, never the fresh drawing's hash. HKDF-SHA256 derives a 32-byte AES-GCM key from the ASCII passcode, salt and UTF-8 info `edgecare.referral.v1`. Ciphertext is CryptoKit's combined nonce (12 bytes), ciphertext, tag (16 bytes), base64 encoded. HKDF is allowed by the brief, but four digits have only 10,000 possibilities; this demo scheme is vulnerable to offline guessing and is not production-grade biometric protection.

## Offline semantics

The native outbox stores encrypted enrollment payloads durably. Sync order is chain create, backend post, then remove the queued item; retries are idempotent. `DEMO_MODE` or an offline configuration selects only local adapters and makes no network requests. Mock spends persist locally. Separate devices have separate mock registries; they do **not** share state magically. Cross-device mock transport and spend reconciliation are future integration work. A queued enrollment or offline spend is provisional until acknowledged by the shared registry; first accepted spend wins. Never present local verification as final global settlement.

Expired records cannot be verified by the client. CRM derives `spent` from the registry before checking expiration. Offline verification requires a previously cached enrollment and commitment; a fresh doctor device cannot retrieve unavailable records in airplane mode.
