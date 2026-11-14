# Edge-Care

Four applications for an anonymous cancer-care demonstration, in one monorepo. The kiosk and patient phone share intake, signature enrollment and an encrypted referral wallet. The doctor phone verifies a signature and four-digit code; the web CRM follows referrals and single-use status.

| Application | Implementation |
| --- | --- |
| `apps/kiosk-ios` | SwiftUI iPad intake: structured form, conversational voice, evidence capture and enrollment |
| `apps/patient-ios` | Shared intake, encrypted wallet, referral-ID handoff and patient-controlled profile/history deletion |
| `apps/doctor-ios` | Referral selection, cached verification, signature/PIN checks and spend reconciliation |
| `apps/crm-web` | Next.js clinician workspace, REST API, local SQLite and hosted Neon Postgres |

`packages/edgecare-core` contains shared Swift models, cryptography, signature matching, intake, persistence and sync; `packages/shared-types` contains TypeScript validation, projections and fixtures. [API.md](API.md) documents the shared contract. Design references are in [docs/design](docs/design).

## Run the CRM

Requires Node 22.11+ and pnpm 9.15.9.

```sh
corepack enable
pnpm install --frozen-lockfile
cp apps/crm-web/.env.example apps/crm-web/.env.local
pnpm dev
```

Open http://127.0.0.1:3000 and enter the clinician demo. Three synthetic records seed automatically; SQLite persists under `apps/crm-web/.data/`. Optional issuer and clinician tokens protect shared LAN access. This is a synthetic demo, not a production healthcare service.

## Run the three Apple apps

On your Mac, install full Xcode, its iOS Simulator runtime and XcodeGen (`brew install xcodegen`), then run:

```sh
python3 scripts/run-apple-demo.py --list
python3 scripts/run-apple-demo.py
```

The launcher opens Xcode, runs Swift tests, builds and launches the kiosk on an **M1 iPad Air (5th generation, 10.9-inch)** simulator, the doctor app on **iPhone 15 Pro Max**, and the patient app on **iPhone 13 Pro**. It requests **iOS 27.2.1** exactly and stops with installed alternatives if unavailable. `--runtime latest` explicitly selects a substitute. For private provider setup and a connected voice launch, run `pnpm ios:voice` on the Mac. See [the Mac walkthrough](docs/apple-demo.md) for setup, physical devices and logs.

Connected mode shares the local backend across devices. `--mode local` makes no network calls and gives each device an independent persistent store. Offline connected enrollments and spends queue durably; an offline spend remains provisional until the shared registry accepts it.

## Kiosk language and voice

Patients can complete a structured form offline or have a turn-by-turn voice conversation online. Voice uses ElevenLabs speech recognition with automatic language detection, a server-side conversational assistant that updates an English clinical profile, and ElevenLabs speech in the detected language. The configured multilingual voice can be overridden per language. The six demo languages are English, Finnish, Somali, Arabic, Ukrainian and Nepali.

Voice requires explicit consent, connectivity and server-side ElevenLabs plus Gemini credentials (directly or through Runware). The form remains available without those services. The clinical profile and clinician summary use English; localized replies and patient guidance are separate. No patient voice cloning is performed. See [hosted deployment and Mac connection](docs/deployment.md), the server `.env.example` and [voice setup](docs/voice-intake.md).

## Kiosk appointment booking

The kiosk can book shared demo appointment slots from its welcome screen or after saving a referral. Existing patients verify with their code and signature. Bookings and cancellations persist in the shared backend and appear in the CRM. These are demo appointments; no real clinic booking service is connected. See [appointment setup and Mac update](docs/appointments.md).

## Patient profile and history deletion

On the patient phone, open **My profile** and sign in with the enrolled code and signature. **Delete my profiles and history** permanently removes the displayed profiles, referrals, consultations and appointments from the connected backend and this device, after confirmation. Local mode deletes only local-mode records. See [deletion scope, privacy limits and Mac rebuild](docs/patient-deletion.md).

## Checks and additional tools

```sh
pnpm check                 # strict types and protocol/API tests
pnpm test:launcher         # simulator selection and private voice setup tests
pnpm build                 # production CRM build
pnpm test:browser          # browser/API integration; run build first
pnpm test:swift            # macOS: shared Swift lifecycle tests
pnpm schema               # regenerate referral JSON Schema
pnpm demo:studio          # 90-second Remotion composition
```

Install Playwright Chromium with `pnpm exec playwright install chromium`, or set `EDGECARE_TEST_CHROME` to an existing compatible Chrome executable. `EDGECARE_TEST_DEV=true` uses a development server for browser tests instead of the production build.

The [Anchor registry and signed devnet CLI](programs/edgecare-registry/README.md) are separate from the native connected-demo HTTP registry. Devnet needs a deployed program and funded signer; no transaction or deployment has been performed. The [Remotion composition](demo/remotion/README.md) accepts actual product recordings and an optional generated ElevenLabs voiceover; its default scenes are explicitly labeled storyboards.

On-device Apple Vision OCR is implemented. No Nemotron/Core ML weights or validated lesion assessment are bundled. Signature matching and workflow priority scores are demonstration logic, not clinical or identity assurance. Native compilation/device checks and live provider calls require the tools and credentials described in [verification](docs/verification.md).
