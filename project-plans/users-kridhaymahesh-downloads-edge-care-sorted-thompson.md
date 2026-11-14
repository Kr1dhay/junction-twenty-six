# Translated, recorded consultation in the doctor app

## Context

The doctor app (`DoctorVerificationView` in `packages/edgecare-core/Sources/EdgeCareUI/DoctorView.swift`) currently ends once the patient is verified, with an optional "Mark referral as used". The language barrier, which is the core problem Edge-Care addresses, still exists during the visit itself. This plan adds a **Start consultation** button to the verified state. It opens a live, two-way translated consultation that does the following:

- translates speech both ways using **ElevenLabs** (the standard plan, so no enterprise Realtime Translation),
- records the session with **Gemini Live** (`gemini-3.8-live`) as an independent transcript and live notes,
- turns the session into **structured fields the CRM already uses, plus meeting notes** for everything unstructured,
- requires **both parties to confirm** a summary in their own language before anything is saved, so mistranslations and transcription errors are caught,
- saves the confirmed consultation to the CRM as a **new append-only consultation record** linked to the referral. The original triage is never overwritten.

Decisions confirmed with you:
- standard ElevenLabs plan
- speaker direction detected automatically from the spoken language
- a new consultation entity in the CRM
- no audio stored, text only

Constraints from the repo:
- The backend is the Next.js app in `apps/crm-web`, hosted on Vercel (Neon Postgres). Vercel can't proxy WebSockets, so **the server mints short-lived tokens and the phone opens both realtime sockets directly**. API keys stay on the server.
- Swift package has zero third-party dependencies. Use `URLSessionWebSocketTask` and `AVAudioEngine`.
- Anonymous by default. Prompts must strip names and identifiers, and no audio is kept.
- `local` mode (offline/demo) makes no network calls. In that mode the button is disabled with an explanation, and a confirmed consultation queues durably if the network drops after confirmation.

## Architecture

```
Doctor iPhone (one mic tap → 16 kHz PCM16 mono, fanned out)
 ├─ WS ElevenLabs Scribe v3 Live (single-use token, VAD commit, language detection,
 │     secondary_languages=[doctor, patient])
 │     committed segment ─► POST /demo/consultations/translate ─► Gemini/Runware text translation
 │                                                              └► ElevenLabs TTS (target language)
 │     ◄─ original + translation + mp3, played aloud; mic gated while playing
 └─ WS Gemini Live gemini-3.8-live (ephemeral constrained token, TEXT modality,
       inputAudioTranscription, contextWindowCompression, sessionResumption)
       → independent transcript + running "key points" shown to the doctor
End ─► POST /demo/consultations/notes (Gemini structured JSON over both transcripts)
     ─► bilingual review + flags/corrections ─► patient confirms (own language) + doctor confirms
     ─► POST /referrals/:id/consultations (stored) ─► CRM detail "Consultations" timeline
```

**Speaker direction.** A committed segment in the patient's language is labelled patient → doctor. A segment in the doctor's language is labelled doctor → patient. If the language is null or neither of the two, the segment shows as "unclear, please repeat" and is not spoken aloud. The doctor can tap a segment to swap the speaker, which re-runs the translation. The audio session uses `.playAndRecord` + `.voiceChat` for echo cancellation, and the mic chunks are **not sent while TTS plays**, so translated speech is never transcribed again.

## Changes

### 1. Shared contract — `packages/shared-types/src/index.ts`
Add a `consultationSchema` (Zod, strict, snake_case), with fields that mirror the referral's CRM vocabulary:
- `consultation_id` (uuid), `referral_id`, `started_at`, `ended_at`, `doctor_language`, `patient_language`
- `structured`: `presenting_complaint`, `symptoms[]` (English strings, same style as `referral.symptoms`), `duration`, `relevant_history`, `examination_findings`, `clinician_assessment` (only what the clinician said; never AI-generated), `plan`, `follow_up`, `medications_mentioned[]`, `safety_concerns[]`, `recommended_specialty` (nullable)
- `clinical_summary` (English, like `free_text_summary`), `patient_language_summary`
- `meeting_notes` (English, unstructured remainder), `meeting_notes_patient_language`
- `transcript[]`: `{ seq, speaker: doctor|patient, source_language, original_text, translated_text, target_language, speaker_overridden, flagged, correction|null }`
- `recording`: `{ provider: "gemini-live", model, transcript_available, discrepancies[] }`
- `confirmation`: `{ patient_confirmed_at, doctor_confirmed_at, disputed_items[] }`. Both timestamps are required.
- `CRMConsultation` projection (allowlist, the same pattern as `toCRMReferral`), plus `consultationTranslateRequestSchema`, `consultationNotesRequestSchema`, `consultationSessionRequestSchema`.
- Contract test in `packages/shared-types/tests/contract.test.ts`, and regenerate the schema JSON if the generator covers it.

### 2. Server — `apps/crm-web`
- **Refactor `src/server/voice.ts`**: extract `structuredLLM(systemPrompt, context, jsonSchema, zodSchema)` (the existing Gemini/Runware branches) and `synthesizeSpeech(text, language)` (the existing ElevenLabs TTS, `supportsSpeech`, voice lookup, size limits). `runVoiceTurn` keeps its behaviour and calls both, and `tests/voice.test.ts` must still pass.
- **New `src/server/consultation.ts`**:
  - `mintSessionTokens()`: `POST https://api.elevenlabs.io/v1/single-use-token/realtime_scribe` (15-minute token), and `POST https://generativelanguage.googleapis.com/v1beta/auth_tokens` with `uses: 1`, a 30-minute `expireTime`, and `liveConnectConstraints` locked to `models/${GEMINI_LIVE_MODEL}`, TEXT modality, `inputAudioTranscription`, `sessionResumption`, `contextWindowCompression`, and the fixed scribe system instruction. The server owns that instruction, so the client can't change it. If `GEMINI_API_KEY` is missing, it returns `recording: null` and the app labels the session "translation transcript only".
  - `translateSegment()`: a structured LLM call (temperature 0) that returns a literal translation, with no added advice, and treats the transcript as untrusted. It then runs `synthesizeSpeech` in the target language. If TTS fails it still returns text with `speech_available: false`.
  - `draftNotes()`: one structured call over the Scribe transcript and the Gemini Live transcript. It fills the schema fields, puts everything else in `meeting_notes`, writes both language summaries, and lists `discrepancies` where the two transcripts disagree. The prompt forbids diagnosis or inventing facts and strips names and identifiers.
  - New env vars: `GEMINI_LIVE_MODEL` (default `gemini-3.8-live`), `ELEVENLABS_REALTIME_STT_MODEL` (default `scribe_v3_live`). Document both in `.env.example`.
- **Routes** (all use `demoGuard() ?? accessGuard(request, "clinician")`, need `EDGECARE_CLOUD_VOICE=true`, and require `consent: true`):
  - `src/app/demo/consultations/session/route.ts`: POST → `{ scribe: {token, model, url}, live: {token, model, url} | null, expires_at }`
  - `src/app/demo/consultations/translate/route.ts`: POST text segment → translation + optional mp3
  - `src/app/demo/consultations/notes/route.ts`: POST transcript → draft
  - `src/app/referrals/[id]/consultations/route.ts`: GET (clinician session/bearer) list and POST (clinician) store. Returns 404 for an unknown referral and 400 unless both confirmations are present. Idempotent on `consultation_id`, and returns 409 when the same ID arrives with different content.
- **Repositories** (`src/server/repository.ts` SQLite, `src/server/postgres-repository.ts`): add a `consultations(id, referral_id, created_at, payload)` / `edgecare_demo_consultations` table, plus `createConsultation` and `listConsultations(referralId)`. Follow the existing transaction and advisory-lock patterns and the `isDeepStrictEqual` idempotency check.
- **CRM UI** (`src/components/referral-dashboard.tsx` + `globals.css`): `ReferralDetail` fetches `GET /referrals/:id/consultations` when a referral is selected and shows a "Consultations" section between the clinical summary and the status history. For each consultation it shows:
  - the structured fields as a definition list,
  - the meeting notes,
  - a "Confirmed by patient and clinician" badge with times,
  - discrepancies or disputed items highlighted,
  - a collapsible bilingual transcript.

  Use the existing brand tokens, and add `lang`/`dir="auto"` on patient-language text.

### 3. Swift core — `packages/edgecare-core/Sources/EdgeCareCore/`
- `Consultation.swift`: Codable models that mirror the schema, plus a pure `SpeakerResolver` (language → speaker/direction, aliases reused from `voice.ts` normalisation) and a pure `ConsultationReview` state machine: both confirmations are required, and any edit or flag change clears both.
- `ConsultationAPI.swift`: a `ConsultationAPI` protocol, a `RESTConsultationAPI` on top of the existing `DemoHTTPTransport` (clinician bearer, so `issuer: false`; the timeout path is extended for `consultations`), and a `MockConsultationAPI` that throws `.providerUnavailable` in local mode.
- `RealtimeScribeClient.swift`: a `URLSessionWebSocketTask` to `wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=…&token=…&audio_format=pcm_16000&commit_strategy=vad&include_language_detection=true&secondary_languages=…`. It sends `input_audio_chunk` and emits partials and committed segments with `language_code`. It reconnects with a fresh token before the 15-minute expiry.
- `GeminiLiveRecorder.swift`: a WebSocket to `…BidiGenerateContentConstrained?access_token=…`. It sends a `setup` message, streams `realtimeInput.audio` (`audio/pcm;rate=16000`), collects `inputTranscription` and text "key points", keeps the `sessionResumptionUpdate` handle and resumes on `goAway`, and sends `audioStreamEnd` at the end. If it fails, the consultation continues and the recording is marked unavailable.
- `ConsultationOutbox`: a confirmed consultation that isn't yet accepted by the server is stored encrypted with the existing `LocalStorage` key pattern, and is flushed from `NativeSession.sync()`.
- `NativeSession.swift`: add a `consultationAPI` to `connectedDemo` and `local`, plus `startConsultation`, `translate`, `draftNotes`, `submitConsultation` (outbox first, then POST). All are gated on `configuration.allowsNetwork && online`.
- `Models.swift` `CoreError.userMessage`: add consultation-specific copy if needed (for example `.providerUnavailable` reworded for doctors).

### 4. Swift UI — `packages/edgecare-core/Sources/EdgeCareUI/`
- `ConsultationAudio` (new file `ConsultationAudioEngine.swift`): one `AVAudioEngine` input tap → `AVAudioConverter` to 16 kHz Int16 mono, in about 100 ms chunks, fanned out to both clients. Playback of the mp3 uses `AVAudioPlayer`, and the mic stays gated until playback ends. Handle interruptions and route changes the way `ConversationAudio.swift` already does.
- `ConsultationView.swift` (MVVM with an `@Observable ConsultationController`), with these phases:
  1. **Consent**, in both languages (doctor language picker, default English; patient language from `record.language`, changeable).
  2. **Live**: a caption list showing the speaker badge, original, translation and a replay button; a live "key points" panel from Gemini; Pause / End buttons; a connection status line.
  3. **Drafting**: a progress view.
  4. **Review and confirm**: the doctor tab shows the English structured notes, meeting notes and discrepancies, with editable fields and per-segment flag/correct. The patient tab shows the summary in the patient's language with read-aloud (the TTS translate endpoint, or `SpeechController` as a fallback), plus the buttons **"Yes, this is correct"** and **"Something is wrong"**, both in the patient's language. If the patient taps "Something is wrong", the doctor can talk it through live (the session resumes), edit the notes and regenerate the patient summary, and then both must confirm again. Doctor button: "I confirm these notes are accurate".
  5. **Saved / queued**, showing the result state.
- `Copy.swift`: new keys in all 5 languages: `consultConsent`, `consultConfirmPrompt`, `consultConfirmYes`, `consultConfirmNo`, `consultRepeat`, `consultSaved`, `consultReadAloud`. The Arabic layout is RTL, the same as the existing screens.
- `DoctorView.swift` `DoctorVerificationView`: inside the `if let verification` branch, add a section with a **Start consultation** button (`.borderedProminent`, mulberry, min height 48), whether or not the referral is used. Present it as a `.fullScreenCover`. Add a `consultationActive` flag so `onDisappear`, `scenePhase`, and the 2-minute idle timer don't reset `verification` while the consultation is active. Backgrounding pauses the consultation and closes the sockets, but keeps the draft. The button is disabled with a reason when `!app.connected`, when offline, or when `session == nil`.

### 5. Docs
`API.md` (the new endpoints and schema), `docs/decisions.md` (the token-minting design, auto-direction, the no-audio rule, both confirmations required), and `TECH_STACK.md` §5.2/5.3 (Scribe v3 Live, the Gemini Live model) plus `apps/doctor-ios/README.md`. Update the `project.yml` mic usage string to mention the consultation.

## Verification
- `pnpm check` and `pnpm test`:
  - new crm-web tests (`tests/consultation.test.ts`) with mocked `fetch`: the token-minting request shapes (ElevenLabs header, Gemini `liveConnectConstraints`); translate and notes reject invalid provider output; TTS failure falls back to text.
  - routes (`tests/routes.test.ts`): auth is required, consent is required, a missing confirmation gives 400, an unknown referral gives 404, an idempotent retry works, and a conflicting retry gives 409.
  - repository tests for SQLite and Postgres (the existing `postgres-repository.test.ts` harness).
  - existing `voice.test.ts` still passes after the refactor.
- `pnpm test:swift`: `SpeakerResolver` (patient and doctor languages, null, other), the `ConsultationReview` rule (an edit clears both confirmations, and submit is blocked until both confirm), Codable round-trip against a TS-generated JSON fixture, and outbox persistence and replay with `MockConsultationAPI`.
- Playwright (`tests/clinical-flow.spec.ts`): POST a confirmed consultation through the API, and check that the CRM detail shows the Consultations section with the structured fields and the confirmation badge.
- `pnpm ios:generate` + `xcodebuild` for `EdgeCareDoctor` (Swift 6 strict concurrency).
- Manual end-to-end on a device in connected mode against the hosted backend:
  1. Verify the patient and start a consultation.
  2. Speak English and Finnish/Somali, and check the direction, the audio playback, and that there's no echo loop.
  3. End the session, flag a segment, check that both confirmations reset, and confirm both.
  4. See the record in the CRM within one poll.
  5. Turn on the "Simulate offline" toolbar toggle after confirmation, and check that it queues and then syncs.

Also confirm that Scribe v3 Live recognises Somali and add a note to `docs/voice-intake.md`. If it doesn't, keep the batch `scribe_v2` per-segment path as the fallback for that language.
