# Optional voice research — not cancer screening

## Scope and readiness

The intake offers an optional voice-pattern research task after relevant reported
throat/voice symptoms and emergency questions. It does not infer cancer from
ordinary conversation. Emergency advice takes precedence and is shown first,
but the optional research offer still appears alongside it. Declining, being offline or
an unavailable model never blocks the referral.

**This is not a clinically validated cancer classifier.**
The numeric model export is tracked in this private hackathon repository at the
owner's request and is not enabled automatically. The explicit local hackathon
mode can prepare and run the pinned audio-only benchmark model. Consent and a
research label do not substitute for clinical validation, ethics approval or
applicable medical-device requirements.

The original inference worker supports an approved MFCC/standard-scaling/
logistic-regression JSON artifact. An arbitrary upstream pickle is not
compatible merely because its filename mentions MFCC.

## Local hackathon model

`services/voice-research/prepare_benchmark.py` downloads the actual
`LR_MFCC_Rec_Only.pkl` from commit
`7811f6d8cc8ac6dbe8535e9e2669febed4f51da4`, checks its fixed SHA-256, and exports
numeric JSON after 12 software-parity checks. Conversion uses a closed
deserialization allowlist; the web worker never loads pickle or imports upstream
Python. Feature selection (29 features), float32 arithmetic, class ordering and
the learned 77-frame MFCC length are preserved. Labels are `Benign` and
`Malignant`; the upstream training definition also groups dysplasia with the
positive class. This is not the paper's best-performing model.

The demo is opt-in via `--acknowledge-unlicensed-local-demo`; no clinical
approval is fabricated. Raw upstream pickle is not bundled.
`run_demo.py` starts a loopback-only worker and isolated CRM/backend with an
independent SQLite database, without changing hosted services or existing device
settings. See the worker README for commands and simulator connection.

## Sources reviewed

- [Mary Paterson et al. benchmark](https://github.com/mary-paterson/LaryngealCancerClassificationBenchmark):
  the strongest candidate. Includes pretrained logistic regression, SVM and MLP
  pipelines, including audio-only variants. Inference uses 16 kHz audio and MFCC,
  openSMILE or wav2vec2 features. MFCC preprocessing clips/pads a learned number
  of frames then flattens them.
- [Larynx_cancer](https://github.com/muhammadmo/Larynx_cancer):
  a research notebook/data, not a documented deployed inference service.
- [oral_cancer_analysis](https://github.com/karkirowle/oral_cancer_analysis):
  oral-cancer speech research, a different target and recording setting. The
  README says neural-network training code is not included.
- [vocalfolds](https://github.com/imesluh/vocalfolds):
  endoscopic-image segmentation, not voice classification; 536 images from two
  patients. It is not suitable for classifying phone voice.

The [benchmark paper](https://arxiv.org/abs/2412.16267) reports 84.0% sensitivity,
83.3% specificity and 0.918 AUROC for its best model. These are the study's
results, not performance of this implementation. Classification of benign
versus malignant voice pathologies in selected datasets does not establish
performance for unselected kiosk users, phone microphones, other languages,
healthy voices or general “throat cancer.” No cancer probability is reported.

## Recording, safety and privacy

The [NHS symptom guidance](https://www.nhs.uk/conditions/laryngeal-cancer/symptoms/)
includes persistent voice changes, neck lumps and swallowing problems, and
explains that these commonly have other causes. Keyword matching only selects
whether to offer a task; it is not diagnosis or triage. English negation/family
history checks are limited. The patient must confirm that these are their own
symptoms. This is not validated multilingual clinical language understanding.

A separate six-second sustained “aaah” is recorded in iOS `.measurement` mode as
mono, 16 kHz, 16-bit PCM WAV. Echo-cancelled `.voiceChat` consultation audio,
translated playback and Gemini Live intake audio are never reused. The patient
is told to stop if uncomfortable or breathless. Separate explicit consent and
pressing Record are required before capture/upload. The temporary local WAV is
deleted after completion, cancellation or failure. Backend/worker code does not
persist audio or log request bodies; hosting/proxy logging must match this
policy. Recordings are potentially identifying even without a name.

Quiet/clipped samples abstain. These checks do not establish that a sample is a
vowel, verify a speaker, or detect every out-of-domain recording. More rigorous
quality/OOD checks and clinical review are necessary before a real study.

Results are `flagged`, `not_flagged` or `inconclusive`, with explicit
non-diagnostic language. “Not flagged” cannot rule out cancer or other illness.
Every outcome retains advice to obtain clinician review of persistent symptoms.
Research output does not change risk scores, urgency, specialty or emergency
guidance. The record's optional `voice_research` contains model/version,
timestamp, duration and outcome, but no audio, embeddings, demographics or
probability. Results are shown to the patient, on their handoff, in the doctor
app and CRM. Legacy records still decode. Updates preserve existing research
results when no new task is taken.

## Configuration and verification

See [worker setup](../../services/voice-research/README.md). Next.js requires
`EDGECARE_VOICE_RESEARCH=true`, `VOICE_RESEARCH_URL`, `VOICE_RESEARCH_TOKEN`,
`VOICE_RESEARCH_MODEL_ID` and `VOICE_RESEARCH_MODEL_VERSION`. Do not enable them
before artifact authorization and parity checks. Adding source does not modify
the deployed CRM/backend.

Tests use synthetic audio and explicitly synthetic arithmetic fixtures; the
opt-in converter also checks the real pretrained model against the exported
implementation. No patient audio or cancer dataset is downloaded. The local
HTTP smoke test uses the real model on synthetic sound and verifies result
persistence and CRM projection. Tests cover consent, bounded WAV parsing,
abstention, identity checks, legacy schemas, record persistence, emergency
precedence, unchanged triage and exclusion of audio/probabilities. Passing
software tests is not clinical validation.
