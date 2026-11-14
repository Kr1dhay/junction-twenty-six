# Voice-pattern research worker

**Not a cancer test. A real pretrained model is available for an explicit local
hackathon demo; normal serving remains disabled without configuration.**

The standalone Python CPU worker is called by the authenticated Next.js backend.
The exported numeric weights and provenance are tracked for this private
hackathon project at the owner's request. The serving worker loads only checksum-pinned numeric
JSON, contacts no LLM and stores no audio. A separate offline tool downloads one
specific pretrained model and checks parity before exporting it. See
[research review](../../docs/research/voice-assessment.md).

## Quick start: local conceptual hackathon demo

From the repository root:

```sh
python3 -m venv services/voice-research/.venv
services/voice-research/.venv/bin/pip install -r services/voice-research/requirements-converter.txt
services/voice-research/.venv/bin/python services/voice-research/prepare_benchmark.py --acknowledge-unlicensed-local-demo
services/voice-research/.venv/bin/python services/voice-research/run_demo.py --acknowledge-unlicensed-local-demo
```

The runner starts the real-model worker at `http://127.0.0.1:8091` and a local
CRM/API at `http://127.0.0.1:3100`. It uses Node 22 through `npm exec` for SQLite
compatibility. It does not deploy anything, overwrite `.env`/device settings, or
reuse your normal referral database. Its isolated SQLite store and logs are in
`artifacts/voice-demo/`. The virtual environment, private connection settings,
logs and recordings are ignored by Git. Only the pinned JSON weights, manifest
and model README are tracked. Ctrl+C stops only the services this runner started.

The pinned source is `LR_MFCC_Rec_Only.pkl` from benchmark commit
`7811f6d8cc8ac6dbe8535e9e2669febed4f51da4`. The exporter checks SHA-256
`c7278909c9961ec675bdacd63acd5c4862c49274b1ccd56b781387ed272d1853`,
uses a closed deserialization allowlist, verifies `Benign`/`Malignant` class
ordering, preserves all 29 selected features and the float32 arithmetic, and
checks 12 software-parity cases. It never imports the repository's Python code.
The learned MFCC length is 77 frames: longer recordings are truncated by the
original preprocessing. This is not the paper's best-performing model.

Synthetic parity samples do not validate phone microphones, recording
conditions, or cancer detection.

### Connect the app

Build/install the updated kiosk, patient or doctor app. Launch against
`http://127.0.0.1:3100` with the private issuer/clinician tokens in
`artifacts/voice-demo/connection.json` (mode 0600). Never paste these tokens into
Git or into chat.

For an already-installed app on an **explicitly selected** simulator, add
`--launch-simulator YOUR_UDID` to the runner command. For doctor/patient apps also
pass `--bundle-id org.edgecare.demo.doctor` or `org.edgecare.demo.patient`.
This restarts only the selected app and does not erase/uninstall it.

In intake, select “Another health concern”, enter “My voice has been hoarse for
three weeks”, and complete the safety questions. On the evidence screen, consent
to the optional voice task, record six comfortable seconds of “aaah”, inspect
the research result, and complete the referral. The doctor/CRM sees the same
saved result. You can skip the task at any time. Do not use it for patient care.

Physical iPhones cannot reach a Mac via `127.0.0.1`; they need a separately
configured reachable HTTPS backend/worker. The hosted Vercel CRM is unchanged.

### End-to-end check

With the runner active, from the repository root:

```sh
npm exec --yes --package=node@22 -- node node_modules/tsx/dist/cli.mjs scripts/voice-research-smoke.ts
```

This sends synthetic sound to the actual model, checks auth/consent/quiet
abstention, and saves a clearly labelled synthetic referral in the isolated
local database to verify retrieval and CRM projection. It is not a clinical test.

## Artifact contract

The supported preprocessing/inference contract is:

1. Decode mono 16 kHz PCM to floating-point samples.
2. `librosa==0.10.2.post1` MFCC: 20 coefficients, 2048 FFT, 512 hop,
   128 mel bands, DCT-II/orthonormal; other librosa defaults apply.
3. Clip/zero-pad to the artifact's `target_frames`, row-major flatten.
4. Standardize with supplied per-feature `mean` and positive `scale`.
5. Apply supplied logistic-regression `coefficients` and `intercept`.
   The boundary is zero; no probability is exposed.

The benchmark export additionally supplies `arithmetic` =
`sklearn-float32-selected-v1` and `selected_indices`, preserving in-place float32
scaling and feature-selection order. Ordinary artifacts retain the original
double-precision arithmetic contract.

Required JSON fields:

| Field | Requirement |
| --- | --- |
| `feature_extractor` | `librosa-mfcc-20-flatten-v1` |
| `model_id`, `model_version` | Nonempty, at most 120 characters |
| `license_reference` | Evidence of permission, not merely a repository URL |
| `positive_class_meaning` | `research_flag`, checked against original class ordering |
| `target_frames` | Integer, 1–400 |
| `mean`, `scale`, `coefficients` | Finite arrays, each `20 * target_frames` long |
| `intercept` | Finite number |

Verify preprocessing, coefficient orientation, class mapping and prediction
parity against the original model on authorized held-out samples. If its
pipeline differs, implement/validate a different contract rather than guessing
weights or using zeros. Loading joblib/pickle can execute arbitrary code: never
load arbitrary pickles into the service. The separate converter accepts only the
reviewed exact hash and a closed list of known estimator/numeric globals.
Synthetic fixtures are tests only, not deployable medical models.

## Run after approval

Use Python 3.11 and an isolated environment:

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Privately configure:

- `VOICE_RESEARCH_APPROVED=true`: authorized research use and parity verification;
  this is not clinical/regulatory approval.
- `VOICE_RESEARCH_MODEL_PATH`: absolute path to an authorized JSON artifact.
- `VOICE_RESEARCH_MODEL_SHA256`: exact SHA-256 supplied separately.
- `VOICE_RESEARCH_TOKEN`: private random service token, at least 32 characters.

The local runner instead sets `VOICE_RESEARCH_HACKATHON_DEMO=true`, which permits
only the pinned demo identity/provenance and does **not** set
`VOICE_RESEARCH_APPROVED=true` or fabricate a licence reference.

From this directory run:

```sh
.venv/bin/uvicorn app:app --host 127.0.0.1 --port 8091 --no-access-log
```

Use authenticated HTTPS for remote access. Keep weights outside Git and outside
publicly served folders. Do not put the worker token into client apps or Xcode
schemes. Do not enable real patient use without an appropriate study, clinical
validation, privacy/security review and applicable regulatory review.

Next.js needs the same token and model identity, plus
`EDGECARE_VOICE_RESEARCH=true` and `VOICE_RESEARCH_URL` (HTTPS origin; HTTP only
for loopback development). Authenticated GET `/health` verifies readiness and
identity. POST `/assess` requires the strict consented `sustained_a`/`measurement`
recording contract. Audio/responses are bounded; one inference runs at a time.
There is no request-body/audio logging or persistent storage in this code.
Configure surrounding hosting and proxies consistently.

## Tests

```sh
.venv/bin/pip install httpx
.venv/bin/python -m unittest discover -p 'test_*.py' -v
```

These test protocol safety, arithmetic, abstention and MFCC execution—not
cancer-detection accuracy.
