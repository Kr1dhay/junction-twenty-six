# Implementation decisions

## Optional voice-pattern research

The separate opt-in voice task is research-only and disabled unless an
authorized model is configured, except for an explicitly acknowledged,
loopback-only conceptual hackathon demo of the pinned benchmark artifact. It
cannot diagnose or rule out cancer and never changes clinical urgency. The
numeric model export is retained in the private repository at the owner's
request. See the
[model review and deployment boundaries](research/voice-assessment.md).

## Earlier implementation decisions

1. The existing `junction-twenty-six` repository is the monorepo root. Next.js hosts the CRM and REST API; SQLite is the persistent demo store. No deployment or account provisioning has been performed.
2. Swift 6/iOS 17 XcodeGen targets share `EdgeCareCore` and `EdgeCareUI`. The three app entry points select role and configuration; shared workflows are implemented once.
3. The user’s later runtime-voice request overrides the original brief’s “ElevenLabs is for the demo video only” requirement. Connected conversational voice now uses ElevenLabs recognition and synthesis with a server-side conversational profile adapter. Explicit consent gates external processing; the complete structured form remains offline.
4. Language detection comes from the audio recognizer, not from interpreting a transcript generated under a fixed locale. The clinical profile uses English, while replies and patient guidance use the detected or chosen language. A configured multilingual voice, optionally overridden per language, is used; the patient's voice is not cloned. Eleven v3 is the default because Multilingual v2 excludes Somali.
5. Profiles are anonymous intake records, not patient accounts. Conversation turns update the current profile before enrollment. A sealed referral is immutable; a new consultation produces a new referral rather than silently replacing a spent commitment.
6. CRM responses use an allowlist that excludes intake source, kiosk identifiers, encrypted signature, salts and commitment material. Private details are encrypted. Clinician summaries intentionally remain readable to the clinician.
7. Local mode is network-free and device-specific. Connected-demo mode opts into the shared HTTP registry. Cached offline spends are provisional; first accepted operation wins. Stable operation IDs distinguish retries after a lost acknowledgement from competing spends.
8. Demo login and device tokens are demonstration access controls, not verified clinician identities. One-click access is loopback-only. Non-loopback access requires configured role tokens; browser sessions expire after eight hours.
9. On-device OCR uses Apple Vision. Nemotron weights, a conversion pipeline and validated lesion assessment are not bundled; unavailable adapters fail explicitly. Scripted guidance never claims a diagnosis or estimates cancer probability.
10. The registry stores an authorized verifier signer. That signer attests off-chain verification; the program does not verify biometrics. The real devnet CLI can create/read/spend deployed accounts, while the native shared-demo path is HTTP. Issuer provisioning, production authorization and native devnet signing require further integration.
11. The brief allows HKDF-SHA256/AES-GCM, which is used consistently across Swift and TypeScript fixtures. A four-digit PIN is vulnerable to offline guessing. Signature DTW is a demonstration matcher without validated false-accept/reject rates. No compliance or strong identity-assurance claim is made.
12. Supplied AstraZeneca colors and Apple layout guidance are applied with system fonts and native controls. No unprovided licensed fonts or AstraZeneca logo assets are invented. Current care-access sources do not support the brief's broad guarantee of free care or universal referral acceptance; that guarantee is not used.
13. The M1 iPad Air is the fifth-generation 10.9-inch model. The Mac launcher requires the requested 27.2.1 simulator runtime unless the user explicitly chooses a substitute. Simulator builds cannot establish physical-device camera, language-recognition or performance compatibility.
14. SQLite driver 11.10.0 and Tailwind 4.1.18 remain pinned for the supplied Node 22.11/glibc 2.31 host. Anchor is pinned to 0.32.1. The lockfile captures the tested JavaScript dependency graph.
15. The doctor app's translated consultation produces a separate, append-only consultation record linked to the referral. It never overwrites the patient's intake triage, so the original referral and the clinician's later findings stay distinguishable. Structured fields mirror the CRM's vocabulary (symptoms, summary, specialty), and anything unstructured goes into meeting notes. Doctor consultations are distinct from decision 5, where a new patient intake produces a new referral.
16. Translation uses the standard ElevenLabs plan, because Realtime Translation is enterprise-only. The pipeline is Scribe v3 Live (realtime STT with language detection constrained to the two consultation languages), then the existing Gemini/Runware text model for a literal translation, then ElevenLabs TTS. Gemini Live (`gemini-3.8-live`) runs in parallel as an independent recorder. Its transcript is cross-checked against the interpreted transcript when the notes are drafted, and disagreements surface as discrepancies.
17. The speaker is detected from the spoken language, not with push-to-talk. Unattributable utterances are never translated or spoken automatically, and the clinician can swap the speaker on any sentence, which re-translates it. The microphone is gated during playback and the audio session uses voice-chat echo cancellation, so translated speech is not re-transcribed.
18. Nothing is saved until both participants confirm the same version: the patient in their own language (read aloud on request), and the clinician in English. Any edit, flag or dispute clears both confirmations. A clinician edit or a corrected translation marks the patient summary stale until it is regenerated, so the patient never confirms outdated content. The server schema requires both timestamps.
19. Hosted serverless functions cannot proxy WebSockets, so the server mints short-lived credentials (an ElevenLabs single-use token, and a Gemini ephemeral token locked to model, modality and the scribe instruction). The device connects directly. Provider API keys stay on the server, and no consultation audio is stored anywhere.

References: [ElevenLabs models](https://elevenlabs.io/docs/overview/models), [Apple M1 iPad Air specifications](https://support.apple.com/en-us/111887), [current care-access context](https://lsv.fi/en/healthcare-for-undocumented-migrants/).
