# Conversational voice and the English profile

The kiosk and patient app offer two intake modes. The structured form works offline; the conversational mode uses Gemini Live exclusively, listens hands-free after one start action, remembers the current conversation, asks for missing information and updates an English clinical profile. Typed turns use the same Gemini Live connection. The legacy HTTP API remains for older clients, but the current voice UI never falls back to ElevenLabs.

## Gemini Live streaming speech

The streaming engine uses Google's `gemini-3.8-live`, the default low-latency native speech model in the [current model guide](https://aistudio.google.com/docs/models). It does not use the extended-thinking variant. Configure these values only on the backend:

```dotenv
EDGECARE_CLOUD_VOICE=true
EDGECARE_VOICE_ENGINE=gemini_live
GEMINI_API_KEY=your-server-side-google-key
GEMINI_LIVE_MODEL=gemini-3.8-live
GEMINI_LIVE_VOICE=Kore
```

After consent and microphone permission, the native app requests `POST /demo/voice/live/session` directly with its issuer credential and bounded current profile/history. Omitting engine discovery saves a network round trip at startup. The server issues a single-use Google token with a one-minute connection window and five-minute lifetime, locked to the selected model and intake configuration. The long-lived Google key never leaves the server. The iPad/iPhone connects directly to Google's constrained WebSocket endpoint; Vercel does not proxy the audio stream. This also avoids serverless WebSocket hosting limitations. [Ephemeral tokens](https://aistudio.google.com/docs/live-api/ephemeral-tokens), [raw WebSocket protocol](https://aistudio.google.com/docs/live-api/get-started-websocket).

AVAudioEngine streams 16 kHz mono PCM input and immediately queues 24 kHz PCM speech output. Apple voice processing is enabled where supported, but is not trusted to prevent Mac-speaker feedback. The current UI uses speaker-safe turn-taking: microphone transmission pauses during assistant speech and its echo tail, with tap-only interruption. Google detects language and speaks in that language using the multilingual Kore voice; no forced language code or ElevenLabs voice ID is sent. All audio parts and both transcription streams are processed, and a provider interruption clears queued speech. Typed turns use the same Live connection without activating the microphone. The existing Runware text model remains available for structured-form normalization and the legacy HTTP turn API.

### Automatic noise adaptation, pauses and interruptions

Gemini Live adapts to ambient microphone levels while listening. There is no quiet setup interval or separate calibration button. The level detector starts with a conservative noise floor and learns a weighted lower percentile of non-voiced samples over a rolling two-second window. Nothing about the noise floor is persisted.

While listening, Gemini uses a 10 dB onset margin, 160 ms sustained onset, up to 400 ms of PCM pre-roll to retain the first syllable, and hysteresis to retain softer syllables. A 700 ms pause queues Gemini's `realtimeInput.audioStreamEnd` immediately after the last PCM chunk on the same sender, explicitly finalizing input using [hybrid VAD](https://aistudio.google.com/docs/live-api/capabilities#hybrid-vad). Server automatic VAD stays enabled as a fallback; this is not a manual `activityStart`/`activityEnd` configuration. Capture continues locally, but idle room noise is not sent as a new stream until the next confirmed onset. No backend deployment is required.

The capture engine stays running during spoken replies, including closing acknowledgements, but captured PCM is withheld before onset detection, pre-roll, and network transmission. Speaking cannot interrupt Edi. Tap the large microphone to interrupt: playback stops immediately, then input automatically rearms after a 500 ms echo-tail hold. The same hold follows each naturally finished question. During the hold, the screen says “Getting ready to listen…”; only then does it show “Speak now.” Capture timestamps reject old echo buffers delivered late to the main actor, and onset/pre-roll are cleared without forgetting the room-noise estimate. Stale output and profile tools are discarded until the old server turn is interrupted or completes. Separate cancelled-turn completion markers and `toolCallCancellation` IDs remain supported.

Microphone permission/input failures have a separate message from provider failures. This level-based gate is not a speech recognizer or speaker identification system: sufficiently loud/changing noise can resemble speech, and quiet voices may fall below threshold. Echo cancellation and actual room-noise performance must be checked on the target hardware. Use headphones when a simulator route cannot cancel its own speaker output.

Tap-only interruption replaces the former amplitude-based spoken barge-in and
its repeated-interruption limiter in the current voice UI. This is a deliberate
tradeoff requested after speaker output was transcribed as patient speech despite
the simulator reporting echo cancellation enabled. It is not a claim that
hands-free acoustic echo cancellation has been fixed.

### Full-screen conversation and follow-up answers

After consent, the large microphone opens a full-screen conversation. Connecting,
Speak now, processing, and speaking have distinct headings. Back stops the
session without discarding the accepted profile. The latest dialogue includes
streaming transcription; the full history and profile remain on the intake page.
The microphone button interrupts a spoken reply, pauses while listening, and
restarts a paused session only when tapped. No extra tap is needed after a question.

Audible PCM is tracked separately from queued silent PCM and remote generation.
Once the spoken question and its echo-tail hold finish, ordinary listening
sensitivity resumes even if Gemini has not yet sent its turn-complete marker. Trailing silence is discarded
after completion. Generation-tagged playback tickets reject stale or duplicate
completions. Input revisions prevent old-response cleanup from consuming a newer
answer. Multiple validated profile updates in a response are acknowledged, not
treated as a provider failure. Silent listening waits 45 seconds.

The structured form's Read aloud explicitly activates an Apple spoken-audio
playback session, exposes preparation/started/unavailable states, and offers Stop
reading. A five-second startup deadline catches unavailable synthesis assets.
Unsupported languages never silently fall back to an unrelated language. Switching
to voice stops Apple speech first; idle voice controllers no longer deactivate an
audio session they do not own.

The model calls `record_intake_profile` after patient input, with the entire English profile and an explicit stop signal. The client validates the payload, computes completeness from concern, symptoms and duration, and acknowledges the tool before the short spoken response. Synchronous tool acknowledgement is supported by this model and ensures a tool-only update cannot silently replace the spoken response. On completion/early stop, capture and the connection close after the closing drains, unless interrupted first. A terminal response that keeps emitting quiet PCM is bounded after 2.5 seconds of played silence following audible speech; a 20-second closing deadline, six-answer cap and five-minute session cap provide further bounds. A stopped incomplete profile stays incomplete.

Pause, consent withdrawal, leaving the intake screen, backgrounding, interruptions and connectivity/provider errors clear streaming resources. A lost session is not silently restarted: the patient explicitly starts again, with the accepted English profile retained. Direct Google audio processing is disclosed in all five UI languages. Native microphone, speaker, echo cancellation and actual latency still need the Mac/device checks below.

Rebuild installed apps on the Mac to enable this transport:

```sh
git pull --ff-only
pnpm install --frozen-lockfile
python3 scripts/connect-hosted.py --config edgecare-device.json --rebuild
```

## Legacy connected voice service

On the Mac, run `pnpm ios:voice` for private credential prompts and a connected simulator launch; see the [Mac setup instructions](apple-demo.md#start-connected-voice-on-the-mac). The wizard does not transfer credentials from other machines or verify provider entitlements. Manual setup follows.

In `apps/crm-web/.env.local`, configure server-side values:

```dotenv
DEMO_MODE=true
CHAIN=mock
LLM=ondevice
EDGECARE_CLOUD_VOICE=true
EDGECARE_VOICE_ENGINE=legacy
GEMINI_API_KEY=your-server-side-key
GEMINI_MODEL=your-available-structured-output-model
ELEVENLABS_API_KEY=your-server-side-key
ELEVENLABS_VOICE_ID=your-selected-multilingual-voice-id
ELEVENLABS_STT_MODEL=scribe_v2
ELEVENLABS_TTS_MODEL=eleven_v3
```

Select a Gemini model available to your account that supports `generateContent` with JSON Schema output. Restart the Next.js server after configuration changes. Provider keys never belong in a native app, browser environment variable or committed file. Launch the native apps in connected mode with the [Mac launcher](apple-demo.md).

The legacy pipeline and structured-form normalization use Gemini through Runware: `VOICE_LLM_PROVIDER=runware`, `RUNWARE_API_KEY` and `RUNWARE_MODEL=google:gemini@3-flash`. The verified Flash model returns structured intake profiles through Runware's [compatible API](https://runware.ai/docs/tools/compatible-apis). The service validates every result and never silently switches models. Historical ElevenLabs voice evidence is listed in [voice selection](voice-selection.md). Older installed native apps continue using the legacy turn endpoint until rebuilt.

The user first gives explicit consent to external processing, then taps **Start conversation** once. The adaptive audio-level detector sends each answer after a 700 ms pause following speech; recordings are limited to 30 seconds. This legacy HTTP path remains half-duplex: the microphone stays off during processing and playback, then resumes after the reply finishes. Barge-in requires Gemini Live. Twelve seconds without speech pauses the session without uploading silence. Pause, backgrounding, audio interruption, revoked consent, offline mode and provider/playback errors stop automatic listening. The patient explicitly starts again to resume. Audio-level detection needs testing on the target microphones and in the intended room.

The required information is the main concern, symptoms (or the relevant concern category for screening/letter requests), and duration. An explicit "I don't know" is recorded as uncertainty; missing answers are never supplied by the server. Optional context is not required. Once these essentials are present, the API returns `intake_complete=true` and `conversation_ended=true`, speaks a short closing without another question, and the microphone remains off. A spoken request to stop sets `conversation_ended=true` without claiming the profile is complete. Patients review the English profile and tap Continue; **Add or change details** deliberately reopens listening for corrections. Automatic conversation also pauses after six answers if essentials remain unclear.

Typed turns use the same profile and conversation without speech recognition, and do not activate automatic listening. A valid text/profile response without speech pauses the hands-free session. Corrections update the current profile before referral enrollment.

## Legacy language behavior

1. ElevenLabs Scribe receives the audio **without a language hint**, and returns the detected language and confidence. Unclear language detection asks the patient to retry or use text.
2. The conversational model receives the transcript, recent turns and existing profile. It returns English concern/symptoms/duration/context, a reply in the detected language, and completion/stop signals. The server determines profile completeness from the essential fields. Corrections are applied to the existing profile.
3. ElevenLabs speaks that reply in the detected language. Use `ELEVENLABS_VOICE_ID_EN`, `_FI`, `_SO`, `_AR` or `_RU` to select a particular voice for a language; otherwise `ELEVENLABS_VOICE_ID` is used. This selects a synthetic voice, not a clone of the patient.

Eleven v3 supports the five demo languages. Multilingual v2 omits Somali, so it is not the default. Unsupported synthesis or a TTS failure returns the valid text/profile turn with a visible speech-unavailable state; it never substitutes English audio for another language. [Speech recognition API](https://elevenlabs.io/docs/api-reference/speech-to-text/convert), [voice models](https://elevenlabs.io/docs/overview/models), [speech synthesis API](https://elevenlabs.io/docs/api-reference/text-to-speech/convert).

## Storage and offline operation

The kiosk welcome screen offers **Create a new referral** and **Update an existing referral**. Updating first checks the existing signature and four-digit code on the device, then decrypts the saved English profile and private notes. If several records match, the patient chooses which one to edit. Voice can apply corrections to the loaded profile; the form is also available. The patient repeats the current safety questions, reviews the changes and chooses **Save update**. No new signature or code is enrolled.

Updates retain the referral ID, creation time, source, encrypted signature, salt, commitment, expiry and used status. Only clinical presentation and encrypted intake details change. The original verification credentials continue to work. An unlocked encryption key is held only in the session and discarded on reset/background timeout; neither the code nor raw signature is uploaded. Connected saves require connectivity and are not queued as new enrollments. Retrying the same prepared save is idempotent; a different edit based on an obsolete record is rejected and requires verification/reloading again.

The synthetic service continues to trust configured device roles: lookup uses the clinician read role already provisioned on the demo devices, and `PATCH /referrals/:id` requires the issuer token. Patient signature/code checks happen in the native app; the backend does not independently authenticate handwriting. Both SQLite and Neon perform compare-and-swap updates under the same referral lock used for registry mutations, preserving single-use state.

After either intake mode, a local safety questionnaire selects relevant questions from the English profile, structured symptom choices and original notes. Cough/breathing, chest symptoms and bleeding receive specific immediate-safety checks. Skin changes, lumps, cough changes, repeated bleeding and screening-letter needs receive relevant follow-ups. A general emergency check remains available for other symptoms. Questions and emergency choices are translated into all five demo languages; no model call is needed to select them.

A positive emergency answer shows the 112 advice immediately. **Continue questionnaire** lets the patient finish the remaining questions if they choose not to call. The final advice screen also offers **Continue with referral**, followed by the normal signature, code and referral steps. Continuing retains the emergency flag, priority, visible advice and answers; it does not report that emergency services were contacted. The continuation choice is stored with the encrypted answers and described in the clinician summary. Back navigation preserves answers for unchanged intake. Help with a screening letter is a routing preference, not a positive emergency or persistent-symptom answer.

The fixed safety wording draws on [HUS emergency care](https://www.hus.fi/en/patient/treatments-and-examinations/emergency-department), [HUS prehospital care](https://www.hus.fi/en/patient/treatments-and-examinations/prehospital-emergency-care), and NHS information on [breathing symptoms](https://www.nhs.uk/symptoms/shortness-of-breath/), [moles](https://www.nhs.uk/conditions/moles/) and [lumps](https://www.nhs.uk/symptoms/lumps/). Symptom matching selects questions; it does not diagnose a condition.

The structured form maps localized choices to English clinical descriptions. Optional original-language notes remain separate, encrypted private detail; they are not represented as translated English. The canonical profile is encrypted with the referral's private triage detail, and its English summary is available in the clinician read model. Patient-language guidance and the original conversation are separate presentation data.

Voice endpoints do not store incoming audio/transcripts in SQLite or application logs. Live audio and session credentials remain in memory and never enter the wallet or outbox; accepted English profiles are encrypted when saving a referral. Legacy native recordings use temporary files removed after sending or cancellation. Providers receive the consented content and their own retention terms apply. `ELEVENLABS_ZERO_RETENTION=true` applies only to the legacy provider and requires its account entitlement; it does not configure Google's retention.

Missing keys, disabled cloud mode, poor connectivity or denied microphone access leave the structured form available. Native local mode makes no network requests at all. Apple on-device dictation/read-aloud, where supported by installed language assets, is a separate optional form aid.

## Verify with synthetic content

Rebuild the native apps after pulling these changes: `python3 scripts/connect-hosted.py --config edgecare-device.json --rebuild` uses the existing booted simulators, runs Swift tests, builds and installs each app, then connects to the hosted backend.

Use a new session for each language: English, Finnish, Somali, Arabic and Russian. Start once and describe a synthetic concern immediately without selecting a speech language. With steady room noise, stop speaking and verify processing begins after a short pause. Verify streamed playback, language switching, quiet speech, room noise, and automatic listening after each reply and its brief echo-tail hold. Play a reply aloud and check that it does not appear as patient speech. Speaking over Edi must not interrupt or upload that sound. Tap the microphone during a reply and during its closing: playback must stop, the short hold must finish, and the next answer must use the correction without stale speech resuming. Repeat after the server has finished generating but audio is still playing. Answer a duration question; an uninterrupted closing must leave the microphone off and the English profile complete. Explicitly reopen to correct the duration. Test silence, a spoken stop while listening, Pause during recording/playback/network processing, consent withdrawal, backgrounding and offline mode; none should restart the microphone. The review and enrolled clinician summary must contain the corrected English duration. Switch to the form and complete a separate enrollment offline. Historical ElevenLabs Somali detection failures do not establish Gemini Live quality; native-speaker review remains necessary.

Automated provider tests validate detection parameters, voice selection, English-profile transport, consent/configuration gates, language mismatches and failures using mocked responses. They do not establish live transcription/translation quality. Actual microphone playback and provider-account checks must be run on the Mac/devices with configured credentials.

## Doctor consultation (realtime)

The doctor app's consultation uses ElevenLabs **Scribe v3 Live** (realtime) rather than the batch Scribe used for intake turns. Recognition is constrained to the two consultation languages (`language_code` = clinician, `secondary_languages` = patient), and each committed sentence's detected language decides the speaker. Somali recognition and detection on the realtime model have **not yet been verified on a device**, and Somali batch detection is already recorded as unverified (see [voice selection](voice-selection.md)). The flow degrades safely: a sentence without a confident language is shown as "unclear", is never translated or spoken automatically, and the clinician can assign the speaker, which then translates it. If Somali proves unreliable, the fallback is per-segment batch `scribe_v2` with an explicit language. Translation TTS uses `ELEVENLABS_TTS_MODEL` (Eleven v3 by default, which includes Somali).

Device check: verify a referral in connected mode, start a consultation, alternate English and the patient's language, and confirm the direction, playback and that there is no echo loop (the microphone is gated during playback). End the session, flag a sentence (both confirmations must clear), confirm on both sides, and check that the record appears in the CRM detail within a few seconds. Repeat with **Simulate offline** enabled after confirmation: the record must show "will upload when online" and upload on the next sync.
