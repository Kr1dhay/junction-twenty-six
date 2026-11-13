# Edge-Care: Master Build Prompt (Project Bible)

You are a coding agent, the lead engineer for **Edge-Care**, a Junction 2026 hackathon build for the AstraZeneca Finland cancer-care challenge. This document is the single source of truth for the project. Read it fully before writing any code. The user will follow this prompt with task prompts (for example "build the scaffold" or "build the doctor's verification app"). Each task prompt names a slice of this document to execute. Do not start building until a task prompt arrives, unless one is attached to this message. If a task prompt conflicts with this document, follow the task prompt and flag the conflict.

---

## 1. Mission

In Finland, cancer screening is free and universal, yet thousands never reach it. The gap is not cost or entitlement. It is language, fear and trust. Edge-Care closes that last mile with an anonymous, multilingual, offline-first kiosk: walk up, speak any language, show a referral letter or a worrying mole, and leave with clear guidance plus a specialist referral that any doctor can honour. No phone, no paper, no ID. The patient scribbles a signature and picks a 4-digit passcode, and Solana seals the referral as a single-use commitment that only that signature and code can reopen. **You ARE the key.**

---

## 2. Problem and evidence

Use these facts in demo copy, the pitch video and any in-app "why this matters" surfaces. Keep the source URLs with the claims wherever they appear.

- About 3,000-6,000 undocumented migrants live in Finland, roughly 90% of them in the capital region. Source: https://lsv.fi/en/healthcare-for-undocumented-migrants/
- Undocumented adults only gained the right to necessary non-urgent care on 1 Jan 2023. Before that, care was emergency-only. Source: https://eurohealthobservatory.who.int/monitors/health-systems-monitor/updates/hspm/finland-2019/extension-to-the-undocumented-migrants-right-to-health-care
- Even people entitled to care rarely use it. Barriers: language and communication, lack of information, and fear. Source: https://link.springer.com/chapter/10.1007/978-3-030-68414-3_5
- Women of Russian, Somali and Kurdish origin in Finland have clearly lower cervical cancer screening participation than the general population, despite the free universal programme. Sources: https://pmc.ncbi.nlm.nih.gov/articles/PMC5935973/ and https://doi.org/10.3390/ijerph17217899

Pitch line: **Coverage exists, uptake doesn't. The last mile is language, trust and fear.**

Context worth knowing:

- In the Finnish public cancer pathway, the median wait is 207 days vs 123 days in private care.
- Cancer death rate is 48% for the lowest education group vs 27% for the highest.

---

## 3. Design principles

1. **Anonymous by default.** No accounts, no names, no email, no phone number, no ID. The system never learns who the patient is.
2. **You ARE the key.** Identity for a referral is a handwritten signature plus a 4-digit passcode. Nothing printed, nothing carried, nothing to lose, steal or have found on you. For someone who is undocumented, carrying nothing is a feature.
3. **No reset, said honestly.** Anonymity means no password recovery. A forgotten passcode loses the referral. The UI must say this plainly at enrollment, in the patient's own language, and keep the code to 4 digits the patient picks themselves, entered twice.
4. **Offline-first.** Every patient-facing flow must complete with the device in airplane mode. The demo literally flips to airplane mode mid-flow and everything keeps working. Treat connectivity as a bonus, never a requirement.
5. **Voice and non-verbal parity.** Anything sayable must also be typeable. Non-verbal users get the full flow through touch and text.
6. **On-device intelligence.** Reading letters and images happens on-device. Private health data does not leave the device unless the patient causes it to.
7. **Doctor side is boring on purpose.** Clinicians get a clean, fast, trustworthy tool. No identity, no accounts for patients, just anonymous referrals and a verification step.

---

## 4. Personas

- **The patient (kiosk or own phone).** An undocumented or marginalised person in Helsinki. May speak Somali, Arabic, Russian, Kurdish, Romani or Finnish. May be non-verbal or low-literacy. Fears authority, paperwork and being identified. Has a health worry or a Finnish screening letter they cannot read.
- **The doctor (CRM + verification app).** A GP or specialist who receives Edge-Care referrals. Sees only anonymous referral records. Verifies the patient in front of them by signature + passcode, then treats.
- **The demo audience (judges).** Junction judges and AstraZeneca/NVIDIA/Solana sponsors watching a video-driven demo. They need to feel the problem, see the offline moment, and understand the signature-as-key mechanism in under 3 minutes.

---

## 5. System overview

Four systems, one protocol.

```
                +----------------------+
                |   1. Kiosk iPad app  |  (Swift, public kiosk hardware)
                |  triage + referral   |
                +----------+-----------+
                           | creates
                           v
              +---------------------------+
              |  ANONYMOUS REFERRAL       |
              |  - triage summary         |----> 2. Doctor CRM (web)
              |  - risk score             |      doctor browses referrals
              |  - commitment hash        |
              +------------+--------------+
                           |
        Solana commitment account (hash + spent flag)
                           |
              +------------v--------------+
              | 3. Doctor verify app      |  (Swift)
              | signature + passcode ->   |
              | fuzzy match, mark spent   |
              +---------------------------+

                +----------------------+
                | 4. Patient iOS app   |  (Swift, kiosk substitute)
                | same flow, own phone |
                +----------------------+
```

- **System 1 - Kiosk iPad app (Swift).** The physical kiosk in libraries, pharmacies and post offices. Auto-detects the patient's language. Conversational voice and typed input. Reads photos of referral letters or skin lesions on-device. Triage ends in guidance or a referral. Referral is sealed with signature + passcode as a Solana commitment.
- **System 2 - Doctor CRM (web app, React/Next.js + TypeScript).** Where doctors see all their anonymous patients: referral records, triage summaries, risk scores, statuses (open / spent / expired). No patient identity exists to show.
- **System 3 - Doctor verification app (Swift).** Used at the appointment. The patient types their 4-digit passcode and scribbles their signature on the doctor's device. The app fuzzy-matches the signature, checks the commitment on-chain, confirms it is unspent, and marks it spent.
- **System 4 - Patient app (Swift).** A full kiosk substitute on the patient's own phone. Same on-device processing, same commitment scheme, still decentralised and anonymous. For people who have a phone but no access to a kiosk.

System 1 and System 4 produce identical referral records and commitments. Systems 2 and 3 consume them.

### 5.1 Integration contract - how every system links

There is exactly one off-chain backend and one on-chain program. Every system links through them; no system ever talks directly to another system.

Off-chain backend (REST API + database), the CRM's source of truth:

- `POST /referrals` - Systems 1 and 4 submit a new encrypted ReferralRecord (queued locally when offline, synced when connectivity returns). Idempotent on referral_id.
- `GET /referrals` and `GET /referrals/:id` - System 2 (CRM) reads the anonymous referral list and detail. No patient identity fields exist.
- Statuses (open / spent / expired) come from reconciling the database with the chain.

On-chain (Solana program): `create_commitment(referral_id, hash)` on enrollment; `spend_commitment(referral_id)` from System 3 on successful verification.

Link rules per system:

1. **Kiosk iPad app:** writes referrals to the backend and commitments to the chain. Queues both when offline and syncs when back online.
2. **Doctor CRM:** reads every referral from the backend and watches the chain (poll or websocket subscription), so a referral's status flips to spent within seconds of System 3 marking it. Never writes patient data.
3. **Doctor verify app:** reads the referral from the backend, verifies signature + passcode against the chain, then calls `spend_commitment`. The CRM reflects the change via rule 2.
4. **Patient app:** identical write path to the kiosk. The CRM cannot tell - and does not need to know - which system created a referral.

Write this contract once as a shared spec (OpenAPI or a markdown API doc in the repo root) before any system is scaffolded; every system prompt references it.

---

## 6. The identity and referral protocol

This is the heart of the product. Implement it once, in shared code, and reuse it in every Swift app and in the CRM's read model.

### 6.1 Enrollment (kiosk or patient app)

1. Patient completes triage and qualifies for a referral.
2. The app asks the patient to draw their signature on the touchscreen. Capture stroke data: point sequences, timing, pressure where available.
3. On-device, extract a signature feature template from the strokes.
4. Patient picks a 4-digit passcode, enters it twice to confirm.
5. Generate `referral_id` (UUID) and a random `salt`.
6. Compute the commitment: `SHA-256( signature_template_hash || passcode || referral_id || salt )`.
7. Build the referral record (see data model). Encrypt the sensitive parts (signature template, full triage detail) with a key derived from `passcode || salt` (PBKDF2 or HKDF).
8. Write the commitment hash to the Solana commitment account, flagged unspent. Only the hash goes on-chain. Never raw answers, never the signature, never the passcode. This keeps it GDPR-safe.
9. When online, sync the encrypted referral record to the CRM backend. When offline, queue it locally and sync later. The referral is valid either way, because verification only needs the signature, the passcode and the chain.

### 6.2 Verification (doctor app)

1. Patient arrives at the doctor. Doctor opens the referral in the verify flow (scan/select by referral_id, or the patient app hands it over).
2. Patient types their 4-digit passcode on the doctor's device.
3. Patient re-scribbles their signature on the doctor's device.
4. The app decrypts the enrolled signature template using the passcode, fuzzy-matches the fresh signature against it (stroke-feature similarity above a tuned threshold; DTW on normalised stroke sequences is fine).
5. The app recomputes the commitment hash and checks the on-chain account: hash must match and `spent` must be false.
6. On success: show the green verified state and mark the commitment spent on-chain. Single-use enforced. On failure: clear, kind, non-accusatory retry state.

### 6.3 Rules and honest trade-offs

- Raw biometrics never leave a device unencrypted. Only hashes go on-chain.
- No reset. A forgotten passcode loses the referral. This is a deliberate trade: perfect anonymity means no recovery channel. UX copy must say this at enrollment.
- For the hackathon build, keep the crypto real but simple: SHA-256 commitments, standard KDF, and an Anchor program with `create_commitment` and `spend_commitment` instructions. A local mock chain behind a protocol is required for the offline demo (see section 9).

---

## 7. Data model

Shared across all four systems. Keep these schemas in shared packages so the apps and the CRM never drift.

### 7.1 ReferralRecord

```json
{
  "referral_id": "uuid",
  "created_at": "iso8601",
  "source": "kiosk | patient_app",
  "kiosk_id": "string | null",
  "language": "bcp47 code detected or chosen",
  "symptoms": ["structured symptom codes"],
  "free_text_summary": "short triage summary in English for the doctor",
  "patient_language_summary": "short guidance in the patient's language",
  "risk_score": "0-100",
  "risk_band": "low | medium | high",
  "recommended_specialty": "e.g. dermatology, gynaecology",
  "letter_scan": { "present": true, "extracted_text": "string | null" },
  "lesion_photo": { "present": true, "assessment": "string | null" },
  "signature_template_encrypted": "blob (KDF(passcode, salt))",
  "salt": "base64",
  "commitment_hash": "sha256 hex",
  "status": "open | spent | expired",
  "expires_at": "iso8601"
}
```

### 7.2 On-chain commitment account (Solana PDA, seeded by referral_id)

```
commitment_hash: [u8; 32]
spent: bool
created_slot: u64
spent_slot: u64 | null
```

### 7.3 What the CRM can see

Everything above EXCEPT: signature template, passcode material, and any identity (there is none). The CRM renders anonymous referral cards: referral_id (short form), triage summary, risk band, language, recommended specialty, status, created_at. Sort and filter by status, risk band, specialty and date.

---

## 8. The four systems in detail

### 8.1 System 1: Kiosk iPad app (Swift, SwiftUI)

Runs on an iPad mounted in a public kiosk. Always-on, anonymous, self-service.

Flow:

1. **Welcome.** Language auto-detect from the first spoken or typed words. Big friendly language switcher always visible. Languages to demo: Finnish, English, Somali, Arabic, Russian.
2. **Conversation.** The patient describes their concern by voice (on-device speech recognition) or by typing (full non-verbal parity). The conversational layer asks follow-up questions, calms fears, and keeps language simple (reading age ~10).
3. **Evidence capture.** Optional: photograph a referral or screening letter (Nemotron VL reads it on-device, any language) or photograph a skin lesion (Nemotron VL assesses visual warning signs on-device). Nothing uploaded raw.
4. **Triage.** Symptoms compared against cancer warning signs. Outcome: reassurance and self-care guidance, or a specialist referral recommendation with a risk score.
5. **Seal the referral.** Signature capture, 4-digit passcode entered twice, honest no-reset warning, commitment written (queue if offline), clear next steps shown and spoken in the patient's language.

Key requirements:

- Fully functional in airplane mode, end to end.
- Voice: on-device speech-to-text and text-to-speech (Apple Speech / AVSpeechSynthesizer). ElevenLabs is for the demo video voiceover, not the kiosk runtime.
- Large touch targets, high contrast, one question per screen.
- Idle attract screen with a gentle invitation in rotating languages.

### 8.2 System 2: Doctor CRM (web app, React/Next.js + TypeScript)

Not Swift. Doctors live in browsers.

- Anonymous patient list: every referral as a card or row (referral_id short form, risk band with colour, triage summary, language, recommended specialty, status, created_at).
- Filters: status (open / spent / expired), risk band, specialty, date range.
- Detail view: full triage summary, letter-scan extracted text, lesion assessment, status history.
- No patient identity anywhere. No names, no contacts, no accounts for patients. Doctor login can be a simple demo login.
- Status stays in sync with the chain: spent referrals flip automatically when the verify app marks them spent.
- Clean, clinical, calm UI. AstraZeneca branding within Apple-style layout discipline (see section 11).

### 8.3 System 3: Doctor verification app (Swift, SwiftUI)

The in-clinic verification moment. Must feel like magic and take under 10 seconds.

1. Doctor selects the referral (list of open referrals, or the patient states their referral).
2. Patient types their 4-digit passcode on the doctor's device.
3. Patient scribbles their signature.
4. App fuzzy-matches, checks the on-chain commitment, shows a big green VERIFIED state (or a gentle retry), and marks the referral spent.
5. The spent state propagates to the CRM.

Same shared crypto and matching code as the kiosk and patient app. Works offline with the mock chain, syncing the spent flag when connectivity returns (conflict rule: first spend wins).

### 8.4 System 4: Patient app (Swift, SwiftUI)

The kiosk in your pocket, still decentralised.

- The full System 1 flow on the patient's own iPhone: language auto-detect, conversation (voice + typed), letter and lesion capture on-device, triage, referral, signature + passcode commitment.
- Referral wallet: the patient's open referrals live on their device (encrypted). This is the continuity-of-care piece: carry referrals between kiosks, doctors and time.
- Hand-off: show the referral to the doctor's verify app (referral_id display or device-to-device handover).
- Still anonymous. No account, no sign-up, no identity.

---

## 9. Tech stack

| Concern | Choice |
| --- | --- |
| Kiosk app | Swift, SwiftUI, iOS 17+ (iPad) |
| Patient app | Swift, SwiftUI, iOS 17+ |
| Doctor verify app | Swift, SwiftUI, iOS 17+ |
| Doctor CRM | Next.js (App Router), React, TypeScript strict, Tailwind |
| On-device vision-language | NVIDIA Nemotron VL, quantised, on-device (Core ML on Apple silicon). Reads letters and images in any language offline. |
| Conversational layer | Gemini API when online; on-device fallback (quantised Nemotron plus a scripted triage state machine) so airplane mode never breaks the flow |
| Commitment chain | Solana. Anchor program (`create_commitment`, `spend_commitment`). Local mock chain behind a protocol for offline/demo, devnet when online |
| Crypto | SHA-256 commitments, PBKDF2/HKDF key derivation, platform keychain for local secrets |
| Demo video | Remotion (programmatic video) + ElevenLabs (voiceover) |
| Build tooling | Claude Code throughout |

Architecture rules:

- Every external dependency (Gemini, Solana devnet, CRM backend) sits behind a protocol with a local mock implementation. `DEMO_MODE` and airplane mode must never touch the network.
- Shared Swift package (`EdgeCareCore`) holds: data models, commitment crypto, signature template extraction and fuzzy matching, chain client protocol + mock + devnet implementations, triage engine interface.
- Shared TypeScript package holds the matching referral types and read models for the CRM.
- The mock chain is a local, persistent, honest implementation of the commitment protocol (same semantics, same spent rules), so the demo is real even with no network.

---

## 10. Offline and connectivity strategy

- The demo flips to airplane mode mid-flow and everything keeps working. Design for that moment.
- All patient-facing intelligence runs on-device: speech, Nemotron VL, triage fallback, signature capture, crypto.
- The commitment protocol must function against the local mock chain and reconcile later. Referral records queue locally and sync when online.
- The CRM is the only system that assumes connectivity; for the demo it can run against a local backend seeded with realistic anonymous referrals.

---

## 11. Design sources (authoritative UI inputs)

Two markdown documents govern all UI work:

1. **AstraZeneca branding** (markdown, provided by the user)
2. **Apple design styling** (markdown, provided by the user, HIG-derived)

Rules:

- Both are authoritative for UI elements.
- Precedence: **Apple styling wins for interaction patterns, components, layout, navigation and accessibility. AstraZeneca branding wins for brand elements: colours, logo usage, typography where it does not break accessibility, imagery and tone of voice.**
- If a task prompt asks for UI work and these documents have not been provided, ASK for them before polishing UI. Scaffolding may proceed with plain, native Apple defaults (SF symbols, system fonts, standard components) and clearly marked brand placeholders.
- Never invent brand colours or logos. Use placeholders until the branding document arrives.

---

## 12. Demo strategy

- The demo is **video-driven**: a Remotion-rendered video with an ElevenLabs voiceover tells the story, cutting to live product footage of the vertical slices.
- Prioritise **working vertical slices of the key flows over breadth**. A thin, real, end-to-end path beats a wide, fake one.
- The money shots, in order:
  1. The problem, told with the section 2 stats.
  2. Kiosk: a Somali-speaking patient walks up, airplane mode flips ON mid-flow, the conversation continues, a letter is photographed and read on-device, a referral is sealed with signature + passcode. "You ARE the key."
  3. CRM: the anonymous referral appears on the doctor's screen.
  4. Verify: patient scribbles and types, green check, referral marked spent on-chain.
  5. Patient app: the same power on a phone.
- Build order should follow the money shots.

---

## 13. Repository and build conventions

Monorepo: `edgecare/`

```
edgecare/
  apps/
    kiosk-ios/          # System 1 (Swift, SwiftUI)
    doctor-ios/         # System 3 (Swift, SwiftUI)
    patient-ios/        # System 4 (Swift, SwiftUI)
    crm-web/            # System 2 (Next.js + TypeScript)
  packages/
    edgecare-core/      # Swift package: models, crypto, matching, chain client, triage
    shared-types/       # TypeScript types + read models
  programs/
    edgecare-registry/  # Solana Anchor program
  demo/
    remotion/           # Demo video
  docs/                 # Architecture notes, this brief, design markdowns
```

Conventions:

- Swift 6, SwiftUI, MVVM, iOS 17 minimum. Apple-native components only, no third-party UI frameworks.
- TypeScript strict mode. Next.js App Router. Tailwind for styling.
- Every external service behind a protocol with a mock. Feature flags via a simple config: `DEMO_MODE`, `CHAIN=mock|devnet`, `LLM=ondevice|gemini`.
- Deterministic seeds for demo data so the video story is reproducible.
- Unit tests for crypto, signature matching thresholds, commitment lifecycle (create, verify, spend, double-spend rejection).
- Commit early, commit often, conventional commit messages.

---

## 14. Definition of done for any slice

A slice is done when:

1. It runs in airplane mode (if patient-facing).
2. It uses the shared models and crypto, never local reimplementations.
3. It follows the design-source rules (native defaults + placeholders until branding arrives).
4. The happy path is demoable on device or in the browser, with deterministic demo data.
5. Tests cover the protocol logic it touches.

---

## 15. Out of scope (do not build unless a task prompt says so)

- Real medical diagnosis or validated clinical triage models. This is a demo-grade triage against published cancer warning signs, clearly labelled as such.
- Real patient data, real identities, real payments.
- Kiosk enclosure hardware (Arduino Uno Q, sensors, printers) - a stretch goal only, and there is no printer: nothing is ever printed, by design.
- Accounts, sign-ups, notifications to patients (there is no way to reach an anonymous patient, and that is the point).

---

## 16. How to work with this brief

- This document is the contract. Task prompts name slices of it.
- When a task prompt arrives, restate the slice you are building in one sentence, then build it.
- When something is ambiguous, make the call that best serves the demo and the anonymity principles, note the decision in `docs/decisions.md`, and keep moving.
- If the AstraZeneca branding or Apple design styling markdowns are referenced but missing, ask for them before UI polish.
- Never compromise the two sacred rules: **anonymous by default** and **offline-first**.