# Conversational voice and the English profile

The kiosk and patient app offer two intake modes. The structured form works offline; the conversational mode listens hands-free after one start action, remembers the current conversation, asks for missing information and updates an English clinical profile. Typed turns remain available.

## Enable the connected voice service

On the Mac, run `pnpm ios:voice` for private credential prompts and a connected simulator launch; see the [Mac setup instructions](apple-demo.md#start-connected-voice-on-the-mac). The wizard does not transfer credentials from other machines or verify provider entitlements. Manual setup follows.

In `apps/crm-web/.env.local`, configure server-side values:

```dotenv
DEMO_MODE=true
CHAIN=mock
LLM=ondevice
EDGECARE_CLOUD_VOICE=true
GEMINI_API_KEY=your-server-side-key
GEMINI_MODEL=your-available-structured-output-model
ELEVENLABS_API_KEY=your-server-side-key
ELEVENLABS_VOICE_ID=your-selected-multilingual-voice-id
ELEVENLABS_STT_MODEL=scribe_v2
ELEVENLABS_TTS_MODEL=eleven_v3
```

Select a Gemini model available to your account that supports `generateContent` with JSON Schema output. Restart the Next.js server after configuration changes. Provider keys never belong in a native app, browser environment variable or committed file. Launch the native apps in connected mode with the [Mac launcher](apple-demo.md).

The hosted deployment uses Gemini through Runware instead of a direct Google key: `VOICE_LLM_PROVIDER=runware`, `RUNWARE_API_KEY` and `RUNWARE_MODEL=google:gemini@3-flash`. The verified Flash model returns structured intake profiles through Runware's [compatible API](https://runware.ai/docs/tools/compatible-apis). The Pro model produced prose alongside JSON in a live test, so it was not selected. The service validates every result and never silently switches models. Language-specific ElevenLabs voices and their verification evidence are listed in [voice selection](voice-selection.md).

The user first gives explicit consent to external processing, then taps **Start conversation** once. A local audio-level detector sends each answer after 1.5 seconds of quiet following speech; recordings are limited to 30 seconds. The microphone stays off during processing and playback, then resumes after the reply finishes. Twelve seconds without speech pauses the session without uploading silence. Pause, backgrounding, audio interruption, revoked consent, offline mode and provider/playback errors stop automatic listening. The patient explicitly starts again to resume. Audio-level detection needs testing on the target microphones and in the intended room.

The required information is the main concern, symptoms (or the relevant concern category for screening/letter requests), and duration. An explicit "I don't know" is recorded as uncertainty; missing answers are never supplied by the server. Optional context is not required. Once these essentials are present, the API returns `intake_complete=true` and `conversation_ended=true`, speaks a short closing without another question, and the microphone remains off. A spoken request to stop sets `conversation_ended=true` without claiming the profile is complete. Patients review the English profile and tap Continue; **Add or change details** deliberately reopens listening for corrections. Automatic conversation also pauses after six answers if essentials remain unclear.

Typed turns use the same profile and conversation without speech recognition, and do not activate automatic listening. A valid text/profile response without speech pauses the hands-free session. Corrections update the current profile before referral enrollment.

## Language behavior

1. ElevenLabs Scribe receives the audio **without a language hint**, and returns the detected language and confidence. Unclear language detection asks the patient to retry or use text.
2. The conversational model receives the transcript, recent turns and existing profile. It returns English concern/symptoms/duration/context, a reply in the detected language, and completion/stop signals. The server determines profile completeness from the essential fields. Corrections are applied to the existing profile.
3. ElevenLabs speaks that reply in the detected language. Use `ELEVENLABS_VOICE_ID_EN`, `_FI`, `_SO`, `_AR` or `_RU` to select a particular voice for a language; otherwise `ELEVENLABS_VOICE_ID` is used. This selects a synthetic voice, not a clone of the patient.

Eleven v3 supports the five demo languages. Multilingual v2 omits Somali, so it is not the default. Unsupported synthesis or a TTS failure returns the valid text/profile turn with a visible speech-unavailable state; it never substitutes English audio for another language. [Speech recognition API](https://elevenlabs.io/docs/api-reference/speech-to-text/convert), [voice models](https://elevenlabs.io/docs/overview/models), [speech synthesis API](https://elevenlabs.io/docs/api-reference/text-to-speech/convert).

## Storage and offline operation

After either intake mode, a local safety questionnaire selects relevant questions from the English profile, structured symptom choices and original notes. Cough/breathing, chest symptoms and bleeding receive specific immediate-safety checks. Skin changes, lumps, cough changes, repeated bleeding and screening-letter needs receive relevant follow-ups. A general emergency check remains available for other symptoms. Questions and emergency choices are translated into all five demo languages; no model call is needed to select them.

A positive emergency answer shows the 112 advice immediately. **Continue questionnaire** lets the patient finish the remaining questions if they choose not to call. The final advice screen also offers **Continue with referral**, followed by the normal signature, code and referral steps. Continuing retains the emergency flag, priority, visible advice and answers; it does not report that emergency services were contacted. The continuation choice is stored with the encrypted answers and described in the clinician summary. Back navigation preserves answers for unchanged intake. Help with a screening letter is a routing preference, not a positive emergency or persistent-symptom answer.

The fixed safety wording draws on [HUS emergency care](https://www.hus.fi/en/patient/treatments-and-examinations/emergency-department), [HUS prehospital care](https://www.hus.fi/en/patient/treatments-and-examinations/prehospital-emergency-care), and NHS information on [breathing symptoms](https://www.nhs.uk/symptoms/shortness-of-breath/), [moles](https://www.nhs.uk/conditions/moles/) and [lumps](https://www.nhs.uk/symptoms/lumps/). Symptom matching selects questions; it does not diagnose a condition.

The structured form maps localized choices to English clinical descriptions. Optional original-language notes remain separate, encrypted private detail; they are not represented as translated English. The canonical profile is encrypted with the referral's private triage detail, and its English summary is available in the clinician read model. Patient-language guidance and the original conversation are separate presentation data.

The voice endpoint is stateless: this app does not store incoming audio/transcripts in SQLite or application logs. A native recording uses a temporary file removed after sending or cancellation. Providers receive the consented content and their own retention terms apply. `ELEVENLABS_ZERO_RETENTION=true` requests the provider's zero-retention option only when the account has the required entitlement; it is not enabled by default. No compliance claim is made.

Missing keys, disabled cloud mode, poor connectivity or denied microphone access leave the structured form available. Native local mode makes no network requests at all. Apple on-device dictation/read-aloud, where supported by the installed language assets, is an optional form aid and is distinct from the ElevenLabs conversation.

## Verify with synthetic content

Rebuild the native apps after pulling these changes: `python3 scripts/connect-hosted.py --config edgecare-device.json --rebuild` uses the existing booted simulators, runs Swift tests, builds and installs each app, then connects to the hosted backend.

Use a new session for each language: English, Finnish, Somali, Arabic and Russian. Start once and describe a synthetic concern without selecting a speech language. Pause and confirm automatic submission, then confirm that listening resumes only after the reply. Answer a duration question; the closing must leave the microphone off and the English profile complete. Explicitly reopen to correct the duration. Test silence, a spoken stop before completion, Pause during recording/playback/network processing, consent withdrawal, backgrounding and offline mode; none should restart the microphone. The review and enrolled clinician summary must contain the corrected English duration. Switch to the form and complete a separate enrollment offline. Somali automatic detection remains unverified; see the recorded failures in [voice selection](voice-selection.md).

Automated provider tests validate detection parameters, voice selection, English-profile transport, consent/configuration gates, language mismatches and failures using mocked responses. They do not establish live transcription/translation quality. Actual microphone playback and provider-account checks must be run on the Mac/devices with configured credentials.
