# Conversational voice and the English profile

The kiosk and patient app offer two intake modes. The structured form works offline; the conversational mode uses short recorded or typed turns, remembers the current conversation, asks follow-up questions and updates an English clinical profile.

## Enable the connected voice service

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

The user first gives explicit consent to external processing. Each recording is limited to 30 seconds. Tap the recording control again to send a turn, then hear the reply and continue. Typed conversational turns use the same profile and conversation without speech recognition. Corrections update the current profile before referral enrollment.

## Language behavior

1. ElevenLabs Scribe receives the audio **without a language hint**, and returns the detected language and confidence. Unclear language detection asks the patient to retry or use text.
2. The conversational model receives the transcript, recent turns and existing profile. It returns English concern/symptoms/duration/context plus a reply in the detected language. Corrections are applied to the existing profile.
3. ElevenLabs speaks that reply in the detected language. Use `ELEVENLABS_VOICE_ID_EN`, `_FI`, `_SO`, `_AR` or `_RU` to select a particular voice for a language; otherwise `ELEVENLABS_VOICE_ID` is used. This selects a synthetic voice, not a clone of the patient.

Eleven v3 supports the five demo languages. Multilingual v2 omits Somali, so it is not the default. Unsupported synthesis or a TTS failure returns the valid text/profile turn with a visible speech-unavailable state; it never substitutes English audio for another language. [Speech recognition API](https://elevenlabs.io/docs/api-reference/speech-to-text/convert), [voice models](https://elevenlabs.io/docs/overview/models), [speech synthesis API](https://elevenlabs.io/docs/api-reference/text-to-speech/convert).

## Storage and offline operation

The structured form maps localized choices to English clinical descriptions. Optional original-language notes remain separate, encrypted private detail; they are not represented as translated English. The canonical profile is encrypted with the referral's private triage detail, and its English summary is available in the clinician read model. Patient-language guidance and the original conversation are separate presentation data.

The voice endpoint is stateless: this app does not store incoming audio/transcripts in SQLite or application logs. A native recording uses a temporary file removed after sending or cancellation. Providers receive the consented content and their own retention terms apply. `ELEVENLABS_ZERO_RETENTION=true` requests the provider's zero-retention option only when the account has the required entitlement; it is not enabled by default. No compliance claim is made.

Missing keys, disabled cloud mode, poor connectivity or denied microphone access leave the structured form available. Native local mode makes no network requests at all. Apple on-device dictation/read-aloud, where supported by the installed language assets, is an optional form aid and is distinct from the ElevenLabs conversation.

## Verify with synthetic content

Use a new session for each language: English, Finnish, Somali, Arabic and Russian. Describe a synthetic concern without selecting a speech language. Confirm that the transcript and spoken reply match the language, answer a duration question, then correct the duration in a later turn. The review and enrolled clinician summary must contain the corrected English duration. Switch to the form and complete a separate enrollment offline.

Automated provider tests validate detection parameters, voice selection, English-profile transport, consent/configuration gates, language mismatches and failures using mocked responses. They do not establish live transcription/translation quality. Actual microphone playback and provider-account checks must be run on the Mac/devices with configured credentials.
