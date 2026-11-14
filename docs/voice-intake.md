# Conversational voice and the English profile

The kiosk and patient app offer two intake modes. The structured form works offline; the conversational mode listens hands-free after one start action, remembers the current conversation, asks for missing information and updates an English clinical profile. Typed turns remain available.

## Gemini Live streaming speech

The streaming engine uses Google's `gemini-3.8-live`, the default low-latency native speech model in the [current model guide](https://aistudio.google.com/docs/models). It does not use the extended-thinking variant. Configure these values only on the backend:

```dotenv
EDGECARE_CLOUD_VOICE=true
EDGECARE_VOICE_ENGINE=gemini_live
GEMINI_API_KEY=your-server-side-google-key
GEMINI_LIVE_MODEL=gemini-3.8-live
GEMINI_LIVE_VOICE=Kore
```

After consent, the native app obtains the voice engine from `GET /demo/voice/config`, then requests `POST /demo/voice/live/session` with its issuer credential and bounded current profile/history. The server issues a single-use Google token with a one-minute connection window and five-minute lifetime, locked to the selected model and intake configuration. The long-lived Google key never leaves the server. The iPad/iPhone connects directly to Google's constrained WebSocket endpoint; Vercel does not proxy the audio stream. This also avoids serverless WebSocket hosting limitations. [Ephemeral tokens](https://aistudio.google.com/docs/live-api/ephemeral-tokens), [raw WebSocket protocol](https://aistudio.google.com/docs/live-api/get-started-websocket).

AVAudioEngine streams 16 kHz mono PCM input and immediately queues 24 kHz PCM speech output. Apple voice processing provides echo cancellation where supported; unsupported audio routes use a fresh engine with playback input masking. Google detects language and speaks in that language using the multilingual Kore voice; no forced language code or ElevenLabs voice ID is sent. All audio parts and both transcription streams are processed, and a provider interruption clears queued speech. Typed turns use the same Live connection without activating the microphone. The existing Runware text model remains available for structured-form normalization and the legacy HTTP turn API.

### Microphone calibration and recalibration

Both Gemini Live and the legacy voice path now measure ambient microphone levels before listening. The screen asks the patient to stay quiet for approximately one second, then switches to Listening. A short click does not become the measured room level. The legacy path reuses the measurement for subsequent answers in the same conversation. Starting again or choosing **Recalibrate microphone** measures it afresh while retaining the last accepted English profile and conversation history. No calibration values or calibration recording are persisted.

Gemini uses the measured noise floor with a 10 dB speech-onset margin, a brief sustained-onset check, a 300 ms audio pre-roll to retain the first syllable, and a short release interval to preserve quieter word endings. Below-threshold background input is replaced with zero PCM. Google's automatic voice activity detection still determines turn endings; the local calibration does not send manual activity boundaries or change the constrained server setup. The first calibration interval also sends zero PCM instead of room sound.

During audible assistant playback and its short echo tail, input is masked so speaker audio cannot become another patient answer. Listening resumes automatically after the reply. Patients should wait until Listening before their next answer. This supports turn-taking on speaker-based kiosks and simulator inputs without depending on hardware echo cancellation. The Recalibrate button is available while listening or paused; recalibration starts a fresh consented Live connection rather than changing a locked session configuration.

A loud background shows a translated suggestion to move closer or choose a quieter place and recalibrate. Microphone permission/input failures have a separate message from provider failures. This is audio-level calibration, not a speech recognizer or speaker identification system; actual quiet-voice and room-noise performance must be checked on the target hardware.

The model calls `record_intake_profile` after patient input, with the entire English profile and an explicit stop signal. The client validates the payload, computes completeness from concern, symptoms and duration, and acknowledges the tool before the short spoken response. Synchronous tool acknowledgement is supported by this model and ensures a tool-only update cannot silently replace the spoken response. On completion/early stop, capture stops immediately and the connection closes after the closing drains. A terminal response that keeps emitting quiet PCM is bounded after 2.5 seconds of played silence following audible speech; a 20-second closing deadline, six-answer cap and five-minute session cap provide further bounds. A stopped incomplete profile stays incomplete.

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

The user first gives explicit consent to external processing, then taps **Start conversation** once. A local audio-level detector sends each answer after 1.5 seconds of quiet following speech; recordings are limited to 30 seconds. The microphone stays off during processing and playback, then resumes after the reply finishes. Twelve seconds without speech pauses the session without uploading silence. Pause, backgrounding, audio interruption, revoked consent, offline mode and provider/playback errors stop automatic listening. The patient explicitly starts again to resume. Audio-level detection needs testing on the target microphones and in the intended room.

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

Use a new session for each language: English, Finnish, Somali, Arabic and Russian. Start once, stay quiet during calibration, then describe a synthetic concern without selecting a speech language. Verify streamed playback, language switching, quiet speech, room noise, and automatic listening after each reply. Play a reply aloud and check that it does not appear as patient speech. Change the room noise, choose Recalibrate microphone, and check that the accepted profile remains intact. Answer a duration question; the closing must leave the microphone off and the English profile complete. Explicitly reopen to correct the duration. Test silence, a spoken stop before completion, Pause during recording/playback/network processing, consent withdrawal, backgrounding and offline mode; none should restart the microphone. The review and enrolled clinician summary must contain the corrected English duration. Switch to the form and complete a separate enrollment offline. Historical ElevenLabs Somali detection failures do not establish Gemini Live quality; native-speaker review remains necessary.

Automated provider tests validate detection parameters, voice selection, English-profile transport, consent/configuration gates, language mismatches and failures using mocked responses. They do not establish live transcription/translation quality. Actual microphone playback and provider-account checks must be run on the Mac/devices with configured credentials.

## Doctor consultation (realtime)

The doctor app's consultation uses ElevenLabs **Scribe v3 Live** (realtime) rather than the batch Scribe used for intake turns. Recognition is constrained to the two consultation languages (`language_code` = clinician, `secondary_languages` = patient), and each committed sentence's detected language decides the speaker. Somali recognition and detection on the realtime model have **not yet been verified on a device**, and Somali batch detection is already recorded as unverified (see [voice selection](voice-selection.md)). The flow degrades safely: a sentence without a confident language is shown as "unclear", is never translated or spoken automatically, and the clinician can assign the speaker, which then translates it. If Somali proves unreliable, the fallback is per-segment batch `scribe_v2` with an explicit language. Translation TTS uses `ELEVENLABS_TTS_MODEL` (Eleven v3 by default, which includes Somali).

Device check: verify a referral in connected mode, start a consultation, alternate English and the patient's language, and confirm the direction, playback and that there is no echo loop (the microphone is gated during playback). End the session, flag a sentence (both confirmations must clear), confirm on both sides, and check that the record appears in the CRM detail within a few seconds. Repeat with **Simulate offline** enabled after confirmation: the record must show "will upload when online" and upload on the next sync.
