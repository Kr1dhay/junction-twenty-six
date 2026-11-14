# Kiosk iPad

Generate the Xcode project from root `project.yml` and run `EdgeCareKiosk`. The root Apple demo launcher inspects installed simulator devices and runtimes; it does not assume the requested OS version exists.

The shared SwiftUI flow includes six-language controls (English, Finnish, Somali, Arabic, Ukrainian, Nepali), Arabic layout direction, a structured symptom/duration/severity form, optional original-language notes, offline Apple dictation when supported, letter OCR on device, and optional skin evidence with an explicit absent-model notice. Structured choices map to English clinical fields. No skin diagnosis is performed, and no raw photo is retained or uploaded.

Optional online conversation records up to 30 seconds per turn, uses ElevenLabs language detection and spoken replies with a Google-produced English profile, and supports typed turns and profile corrections. Explicit consent explains the external providers and their retention policies. Without connectivity or configured providers the full structured form remains usable.

Enrollment captures actual signature strokes, asks for a four-digit code twice, requires acknowledgment that there is no reset, and seals through `EdgeCareCore`. The final screen displays the referral ID for clinician handoff. A clearly labelled synthetic sample uses signature + code `1234` for demo smoke checks. It is not a real identity check.

`EDGECARE_MODE=local` (default) uses a durable registry on this device and makes no network calls. `EDGECARE_MODE=connected` uses `EDGECARE_BASE_URL` (default `http://127.0.0.1:3000`), `EDGECARE_ISSUER_TOKEN` and `EDGECARE_CLINICIAN_TOKEN` (legacy `EDGECARE_API_TOKEN` accepted). Info.plist permits HTTP only for localhost and loopback in the local demo; it does not globally disable ATS. A physical device requires a trusted HTTPS backend URL; the shared transport rejects non-loopback plain HTTP. The toolbar can simulate offline; real network changes also update the shared session and trigger reconciliation on reconnect. Local enrollment and offline spends are provisional until the shared demo accepts them. Different devices' local registries do not share state.

The kiosk warns after 150 seconds and clears after 180 seconds without activity; backgrounding or Finish also clears the visible conversation, signature and code and cancels media. Encrypted sealed records/outboxes remain for synchronization. See `API.md` and root docs for the demo's security limits. Native source was reviewed on Linux; compilation, accessibility and device behavior must be checked on a Mac.
