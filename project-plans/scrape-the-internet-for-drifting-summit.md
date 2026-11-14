# Cancer signals from consultation voice and lesion photos: feasibility and implementation

## Context
The user asked two things. First, could the consultation voice recording be screened for throat (laryngeal) cancer? Second, is there a CNN that can assess lesion photos for cancer? They want a feasibility check and then an implementation. Their decisions after the research:
- **Voice:** write up research and feasibility only. No code.
- **Photo:** use a multimodal LLM (Gemini, which is already integrated) to describe submitted lesion photos. This replaces a CNN.

Current state:
- Lesion photos are thrown away. `DeviceMedia.swift` `EvidenceCapture.process()` only sets `lesionPresent = true`.
- `EnrollmentService` writes a hard-coded `LesionPhoto.assessment`: "no medical image assessment was performed".
- `VisionEngine` exists (`EdgeCareCore/Intelligence.swift:142`), with Mock and Nemotron stubs.
- Both clinician UIs already show `lesionPhoto.assessment`: `referral-dashboard.tsx:111` and `DoctorView.swift:194`.

## Feasibility findings (these go in the write-up)
**Voice → laryngeal cancer: not feasible as a product feature right now.**
- No validated library or model exists. The best open benchmark (arXiv 2412.16267, Leeds 2025) reaches 84% sensitivity, 83% specificity and 0.918 AUROC. It used **sustained /a/ vowels**, not conversation, from FEMH (2,000 speakers, one hospital, access on request). The other public set is the Saarbrücken Voice Database.
- Bridge2AI-Voice (PhysioNet, credentialed access) and the OHSU 2025 study found that HNR and F0 separate cancer from healthy voices in men only. The authors call it proof-of-principle.
- In this app, consultation audio goes through `.voiceChat` echo cancellation (`ConsultationAudioEngine.swift:95-100`). That processing distorts jitter, shimmer and HNR. Audio is also mixed with the doctor's speech and the translated playback.
- A possible future path: a separate sustained-vowel task recorded without voice processing. Measure features with Parselmouth/Praat or openSMILE eGeMAPS (eGeMAPS is non-commercial), or use Google HeAR embeddings with a linear probe. Frame it as "dysphonia → consider ENT review", never "cancer detection".

**Photo → skin cancer CNN: models exist, but none is suitable here.**
- ISIC/HAM10000 models on Hugging Face (EVA-02 melanoma, EfficientNet, SkinGuard) are trained on dermoscope images rather than phone photos, are CC-BY-NC, and report their own unverified metrics.
- Google Derm Foundation (embeddings, 448px input, HAI-DEF terms) with a SCIN linear probe was the closest fit for phone photos. One third-party result shows only about 69% accuracy.
- Oral-lesion photo CNNs are papers only, with no public weights.
- Chosen approach: Gemini describes the photo (ABCDE-style visible features plus image quality) for clinician review. It gives no score or probability, it is labelled unvalidated, and it runs only with explicit consent.

## Implementation

### 1. Research write-up
New file `docs/research/cancer-signal-feasibility.md`. It holds the findings above with source links, a "path forward if pursued" section for each modality, and regulatory notes (EU MDR: a diagnostic claim makes this a medical device). Link it from `docs/decisions.md`.

### 2. Backend: lesion description endpoint (`apps/crm-web`)
- `src/server/voice.ts`: extend `StructuredCall` with an optional `image?: { mimeType: "image/jpeg" | "image/png"; base64: string }`.
  - Gemini: add an `inline_data` part beside the text part.
  - Runware: send OpenAI-style `content: [{type:"text"},{type:"image_url", image_url:{url:"data:..."}}]`.
  - Existing callers are unchanged.
- New `src/server/lesion.ts` with `describeLesion(input, config, fetcher)`:
  - Require `consent === true`. Call `assertLLMConfigured`.
  - System prompt: non-diagnostic, describe only visible features (asymmetry, border, colour variation, approximate size if a reference is visible, surface such as bleeding or crusting), image-quality issues, and a reminder to compare with history. Never estimate cancer risk or reassure. If the image is not skin or is unusable, say so.
  - JSON schema returns `observations: string[]`, `image_quality: "adequate" | "limited" | "unusable"`, `quality_notes`, `clinician_summary`.
  - Validate with zod and compose an assessment string with the fixed prefix "AI image description (Gemini, unvalidated, not a diagnosis):".
- New route `src/app/demo/lesion/describe/route.ts`. Copy the pattern from `demo/equity/explain/route.ts`: `demoGuard`, `readJSON` with a size cap of about 8 MB, `runtime="nodejs"`, `maxDuration=45`, and a 503 fallback message. The image is never logged or stored.
- `packages/shared-types/src/index.ts`: add `lesionDescribeRequestSchema` (consent literal true, mime_type, image_base64, language) and `lesionDescribeResponseSchema`.
- Test `apps/crm-web/tests/lesion.test.ts`, in the style of `consultation.test.ts` with a mocked fetcher:
  - consent is required;
  - an inline image part is sent;
  - the schema is validated;
  - a bad provider response gives a 502/503;
  - the output contains no probability.

### 3. Swift client (`packages/edgecare-core`)
- `EdgeCareCore/Intelligence.swift`: replace the `NemotronVisionEngine` stub with a backend-backed `GeminiLesionVisionEngine: VisionEngine`. Its path is `NativeSession` → voice client transport → `["demo","lesion","describe"]`, following `VoiceConversation.swift:107` `send`. Provider keys stay on the server.
  - Before upload, downscale the JPEG to a long edge of about 1024px and strip EXIF by re-encoding with `UIImage`/`CGImage`.
- `NativeSession.swift`: add `describeLesion(image:language:consent:)` with the same guards as `normalizeProfile` (network, online, consent, client). **That file has uncommitted user changes, so edit it additively only.**
- `EdgeCareUI/DeviceMedia.swift` `EvidenceCapture`: add a binding `lesionAssessment: String?` and a consent toggle that reuses the `cloudConsent` copy.
  - On a lesion photo with consent, call the engine, show a busy state, and show the summary to the patient as "sent for clinician review".
  - Without consent, or offline, keep today's behaviour.
  - **This file also has uncommitted changes, so edit additively.**
- `EnrollmentService.swift`: add `lesionAssessment: String?` to `EnrollmentDraft`. Use it in `LesionPhoto(assessment:)` in both `enroll` and `prepareUpdate`, falling back to the current fixed string.
- `IntakeView.swift`:
  - store `lesionAssessment` on the model;
  - reset it in `reset()` and when the photo is removed;
  - pass it to `EnrollmentDraft`;
  - change the line-140 note to include the description.
- `Copy.swift`: update the `vision` and `photoAdded` strings and add `lesionSending` and `lesionConsent` in all 5 languages (en, fi, so, ar, ru).
- Test in `Tests/EdgeCareCoreTests`: draft → record carries the assessment, and the fallback works when it is nil. Use a mock transport for the engine's consent guard.

### 4. Docs
Update `README.md`'s "no validated lesion assessment" line and `TECH_STACK.md` to describe the Gemini description path and its limits.

## Verification
- `pnpm --filter crm-web typecheck` and the crm-web test runner, including the new `lesion.test.ts`.
- `swift test` in `packages/edgecare-core`.
- Manual: with `EDGECARE_CLOUD_VOICE=true` and a Gemini key, run crm-web and POST a sample JPEG to `/demo/lesion/describe` with curl. Check the structured description and that `consent:false` returns 400. Then run the kiosk app, add a lesion photo with consent, submit, and confirm the CRM dashboard "Supporting information" and DoctorView show the description.
