# Multilingual voice selection

Checked 2026-11-14 using only ElevenLabs official public language pages. These are suitable initial candidates for a calm intake assistant, selected from the descriptions embedded in those pages. See `artifacts/voice-selection.json` for exact metadata, synthetic greeting texts, and live probe results.

| Language | Voice | Voice ID | Source |
| --- | --- | --- | --- |
| English | Jon – Support Agent | `MFZUKuGQUsGJPQjTS4wC` | https://elevenlabs.io/text-to-speech/english |
| Finnish | Martti – Calm & relaxed | `paqSK057kuKFy1kq3bdZ` | https://elevenlabs.io/text-to-speech/finnish |
| Somali | Brian – Deep, Resonant and Comforting | `nPczCjzI2devNBz1zQrb` | https://elevenlabs.io/text-to-speech/somali |
| Arabic | Heba Mansuri – Arabic Customer Care | `QsV9PCczMIklRM6xLPAS` | https://elevenlabs.io/text-to-speech/arabic |
| Russian | Egor – Natural, Soothing and Relatable | `qJBO8ZmKp4te7NTtYgzz` | https://elevenlabs.io/text-to-speech/russian |

Jon's description emphasizes a calm, grounded and trustworthy support voice. Martti is described as relaxed and Finnish. Heba explicitly targets calm Arabic customer care and AI agents. Egor explicitly targets soothing Russian conversations and virtual assistants. Brian is comforting and appears on the Somali page; that page lists general voices and does not establish that Brian is a native Somali speaker. Somali pronunciation needs native-speaker review.

All five small greeting probes used `eleven_v3` and an explicit language code. After the user enabled API permissions, all five returned HTTP 200 with nonempty `audio/mpeg`; MP3 files are saved under `artifacts/voice-probes/`. Reported TTS character costs total 41. This verifies account availability and synthesis, but is not a native-speaker pronunciation or subjective audio-quality review. No restricted voice-list endpoint was retried, and no alternative credential was used.

Scribe v2 transcribed the generated English greeting without any language hint: HTTP 200, detected `eng` with probability 0.876235, transcript “Hello, how can I help you today?”. The result is saved in `artifacts/voice-probes/stt-en.json`.

ElevenLabs documents Somali among Eleven v3 languages: https://elevenlabs.io/v3. Keep v3 for Somali; do not silently substitute Multilingual v2, whose supported-language list does not include Somali: https://elevenlabs.io/docs/overview/capabilities/text-to-speech.

The saved synthetic greetings are ready for native-speaker review of language, pronunciation, pace, and warmth. Live synthesis has now succeeded for every selected voice; this does not establish clinical suitability or native pronunciation quality.
