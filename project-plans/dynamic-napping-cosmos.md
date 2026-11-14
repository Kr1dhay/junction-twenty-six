# Skin photo → CNN → Gemini risk score (kiosk demo)

## Context
Today the kiosk throws the skin photo away. `EvidenceCapture.process()` (`packages/edgecare-core/Sources/EdgeCareUI/DeviceMedia.swift:243`) only sets `lesionPresent = true`, and the "decision" is the keyword matcher `OnDeviceTriageEngine` (`Sources/EdgeCareCore/Intelligence.swift:51`). For the teacher-judged proof of concept we want a real two-stage pipeline:

1. **A small CNN as the first stage, committed to the repo.** MobileNetV3-Small (torchvision, ImageNet-pretrained, 2.5M params, BSD) fine-tuned on HAM10000 (7 classes: akiec, bcc, bkl, df, mel, nv, vasc), exported to ONNX and int8-quantised to **about 2 MB**, so it is committed directly with no Git LFS. Expected accuracy is about 75–82%, in line with published MobileNet/HAM10000 results (Skin Lesion Analyser, arXiv 1907.03220: 83%). The larger published checkpoints (EfficientNetV2-S, about 80 MB) were rejected because of their size. I found no tiny HAM10000 checkpoint with published weights and a permissive licence. dermis is GPL-3.0, needs patient metadata and has no weights.
2. **Gemini as the second stage.** Gemini receives the photo, the CNN output and the patient's answers, then returns a 0–100 risk score, a band and a patient-facing warning in the patient's language.
3. **A results screen.** The kiosk shows the score prominently, with **real, cited statistics**, so patients understand when to see a professional.

Decisions taken: the CNN and Gemini both run on the **crm-web backend** (API keys stay server-side), and statistics are real published figures. The score can be jittered a little, as allowed for the demo.

## Backend (apps/crm-web)
**One-off training and export:** `scripts/skin-cnn/train.py` (Python 3.11: torch, torchvision, datasets, onnx, onnxruntime; `requirements.txt` alongside). It runs once on the dev Mac, using MPS if available, in about 20–40 minutes.
- Data: HF dataset `marmal88/skin_cancer` (HAM10000, 600 px images; about 3.7 GB, downloaded to the HF cache, never into the repo). Uses the dataset's own train/validation/test splits.
- Model: `mobilenet_v3_small(weights=IMAGENET1K_V1)`, with `classifier[3]` replaced by `Linear(1024, 7)`.
- Training:
  - 224×224 input, ImageNet mean/std, flips, rotation and colour-jitter augmentation (the colour jitter helps with phone photos).
  - Class-weighted cross-entropy, because nv is about 67% of the data.
  - AdamW at 1e-3 for 8 epochs with cosine decay; the best checkpoint is kept by validation balanced accuracy.
- Export:
  - `torch.onnx.export` (opset 17, input `input` 1×3×224×224, output `logits`).
  - Then `onnxruntime.quantization.quantize_dynamic` to int8 → `apps/crm-web/models/skin-cnn.int8.onnx`.
  - The script **asserts the file is < 5 MB**, then writes `apps/crm-web/models/skin-cnn.json` (labels, mean/std, test accuracy, balanced accuracy, date).
- Both model files are **committed**. `scripts/skin-cnn/README.md` covers the steps, the HAM10000 CC BY-NC 4.0 attribution (fine for this non-commercial demo) and a research-only note.

**`src/server/skin-cnn.ts`**
- Uses `onnxruntime-node` and `sharp` (new dependencies, both added to `serverExternalPackages` in `next.config.ts`).
- Preprocessing: decode → EXIF rotate → resize to 224×224 → normalise with ImageNet mean/std → NCHW float32.
- Returns `{ probabilities: {akiec,bcc,bkl,df,mel,nv,vasc}, top, malignant_probability (mel+bcc+akiec), source: "cnn" }`.
- Reads labels and normalisation from `models/skin-cnn.json`, and adds `onnxruntime-node` and `sharp` to `serverExternalPackages`.
- If the `.onnx` file is missing, returns a seeded random distribution with `source: "simulated"`, so the demo still runs.
- The session is loaded lazily and cached.

**Extend `structuredLLM`** (`src/server/voice.ts:109`)
- Adds an optional `images?: {mimeType, base64}[]`, appended as `inlineData` parts in the Gemini request.
- The skin route forces the Gemini provider (the Runware path is text-only).

**`src/server/skin-assessment.ts` + `src/app/demo/skin/assess/route.ts`**
- Request body (zod, ≤ 8 MiB):
  - `{consent: true, language, image_base64, image_mime, profile, answers, concern}`
  - Guarded with `demoGuard()` and `voiceAccessGuard()`, following the `voice-route.ts` pattern.
- Runs the CNN, then Gemini, with the image and the CNN JSON as context.
- Gemini system prompt, roughly:
  - Role: a dermatology triage-support assistant in a supervised research demo.
  - Weighting: CNN = "first-line, dermoscopy-trained, unreliable on phone photos". Visual ABCDE features (Asymmetry, Border, Colour, Diameter >6 mm, Evolving). The patient's answers (changing, bleeding, itching, duration, new lesion).
  - Score rubric: 0–24 low, 25–49 moderate, 50–74 high, 75–100 very high. High-weight items: changing lesion, bleeding, or CNN mel/bcc > 0.5.
  - Must never state or rule out a diagnosis, and must always recommend a clinician for moderate or above.
  - Output JSON schema: `{risk_score, band, key_factors_english[], patient_message (in the patient's language, ≤ 80 words, calm but direct), clinician_note_english}`.
- After Gemini: the server adds ±4 jitter and clamps to 0–100.
- If Gemini fails: fallback score = 60·malignant_prob + 10 per positive warning answer + jitter, with `source: "fallback"`.
- Response: `{risk_score, band, key_factors, patient_message, clinician_note, cnn, scoring_source}`. The image is never stored or logged.
- Shared zod/TypeScript types go in `packages/shared-types/src/index.ts`, and the new route's checklist goes in `env-check.ts`.

## iOS (packages/edgecare-core)
**`EdgeCareCore/SkinAssessment.swift`**
- `SkinAssessmentRequest` and `SkinAssessmentResult` (Codable, snake_case keys).
- `SkinAssessmentClient`, built on `DemoHTTPTransport` and copying `ConsentGatedVoiceClient` (`VoiceConversation.swift:79`): POSTs to `["demo","skin","assess"]` with `issuer: true`.
- `SkinRiskFacts`: localised, cited statistics per band, from published UK data (BJD 2026 abstracts):
  - "About 7 in 100 people referred urgently for a suspected skin cancer are diagnosed with one" (2023 national median, 7.0%).
  - The conversion rate is higher in people over 80 (16%) and lower under 50 (2%).
  - Melanoma found early has a 5-year survival rate above 90% (I'll verify the exact figure and source from NHS / Cancer Research UK while implementing).
  - Each fact carries its source name, which is shown under the facts.

**`DeviceMedia.swift` (`EvidenceCapture`)**
- On a lesion photo: downscale to a ≤ 1024 px JPEG (q 0.8), keep it in memory only (new `@Binding lesionImage: Data?`), and show a thumbnail.
- Shows an explicit consent toggle before upload: "photo sent to the Edge-Care server and Google Gemini for a demo risk estimate; not stored".

**`IntakeView.swift` / `IntakeViewModel`**
- New fields: `lesionImage`, `photoConsent`, `skinAssessment: SkinAssessmentResult?`.
- In `continueFlow()`: run the existing local triage first (emergency handling is unchanged and takes priority). Then, if a photo exists, consent is given and `app.session` is connected, call `SkinAssessmentClient` and merge the result into `TriageGuidance`:
  - `riskScore`, `riskBand` mapped from `band`, specialty "dermatology".
  - `message` = the patient message followed by the existing guidance.
  - `clinicianSummary` gains the CNN top class, the factors and the clinician note.
  - The label becomes "CNN + Gemini demo estimate · not a diagnosis".
- If the call fails or there is no connection, the flow continues with the local guidance as before.
- `reset()` clears the image and assessment.

**Step 5 UI: new `RiskScoreCard` view**
- A large `0–100` number and a colour-coded `Gauge`/ring: green < 25, amber 25–49, orange 50–74, red ≥ 75 (via `Theme.swift` tokens).
- Band headline, e.g. "High: please book a doctor's appointment soon".
- Up to 3 key factors and the Gemini patient message.
- A "What this means" list of facts with sources.
- A persistent footnote: "Demo estimate from an AI model and a research CNN. Not a diagnosis; only a clinician can assess this."
- VoiceOver label carries the score and band.
- The card shows on the kiosk and patient app whenever `skinAssessment != nil`.

**Persisting and showing the result**
- `EnrollmentService.swift:42,77`: `LesionPhoto.assessment` becomes "CNN: <top> (p=..), Gemini score N/100 (<band>). Raw image not retained."
- `DoctorView.swift:219` already shows `assessment`, so no change there.

**Copy and consent**
- New keys in `Copy.swift`, in all 6 languages: `riskTitle`, band headlines, `factsTitle`, `photoConsent`, `riskDisclaimer`.
- Rewrite the `vision` and `photoAdded` strings, which currently say no model and no upload.
- Update `NSCameraUsageDescription` in `project.yml` and `apps/kiosk-ios/Info.plist`, which currently say "Photos are not uploaded".
- Update the "Optional skin evidence" paragraph in `apps/kiosk-ios/README.md`.

## Tests to update or add
- `Tests/EdgeCareCoreTests/LifecycleTests.swift`: assertions on the "no medical image assessment" text.
- New `SkinAssessmentTests.swift`: decoding, band mapping, guidance merge, and emergency still taking priority.
- New `apps/crm-web/tests/skin-assessment.test.ts`:
  - The route rejects requests without consent.
  - The simulated CNN fallback works when the model file is missing.
  - The Gemini response is schema-validated, with an injected requester as in the existing voice tests.
  - Jitter stays inside 0–100.
- Update the fixtures and `referral.schema.json` only if the `lesion_photo.assessment` format needs it (it is a free string, so probably not).

## Verification
1. Run `python scripts/skin-cnn/train.py` and check its output: test accuracy (≥ 0.70) and balanced accuracy are logged, and `models/skin-cnn.int8.onnx` is < 5 MB (`ls -lh`). The int8 model must agree with the fp32 top-1 on at least 95% of test images.
2. Run `pnpm --filter @edgecare/crm-web typecheck` and the crm-web tests.
3. Start crm-web with `GEMINI_API_KEY` / `GEMINI_MODEL` and `EDGECARE_CLOUD_VOICE=true`. Then `curl` `/demo/skin/assess` with a base64 sample lesion image and confirm the JSON score and the CNN block.
4. Run `swift test` in `packages/edgecare-core`.
5. On a Mac (I can't build iOS here): run XcodeGen, then `EdgeCareKiosk` with `EDGECARE_MODE=connected`. Pick the skin photo, give consent, finish the questions, and check the step-5 risk card and facts. Then complete enrolment and check the assessment line in the Doctor app.
6. Turn the backend off and confirm the kiosk falls back to the local guidance without crashing.
