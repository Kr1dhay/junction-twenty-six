# Multilingual voice selection

The current demo uses Ukrainian in place of Russian. Ukrainian uses the default multilingual voice unless `ELEVENLABS_VOICE_ID_UK` is configured. Ukrainian synthesis, automatic detection, and pronunciation have not yet been verified. The Russian selection and probe results below are historical evidence, not current configuration.

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


## Automatic language-detection probes

Each generated greeting was submitted once to Scribe v2 with **no language hint**. All requests returned HTTP 200. Evidence is saved in `artifacts/voice-probes/stt-{language}.json`.

| Intended language | Detected code | Confidence |
| --- | --- | --- |
| English | `eng` | 0.876235 |
| Finnish | `fin` | 0.997110 |
| Somali | `epo` (Esperanto) | 0.702182 |
| Arabic | `ara` | 0.982511 |
| Russian | `rus` | 0.980831 |

Somali automatic detection **failed** on the short Brian greeting. The original text was “Salaan. Sideen kuu caawin karaa maanta?”; Scribe returned “Salon. Siden ku kawin Kara Manta?”. This test cannot distinguish short-sample ambiguity from pronunciation quality, so Somali spoken-intake coverage remains unverified despite successful TTS synthesis. Do not report full five-language automatic-detection coverage. No retry was made. A native-speaker recording and pronunciation review are needed before making that claim.


## Longer Somali intake probe

A second, longer synthetic input used the same Brian voice and explicit `so` TTS code: “Waxaan qufacayay laba maalmood. Waxaan doonayaa inaan ka hadlo calaamadaha aan dareemayo.” TTS returned HTTP 200, 107,458 MP3 bytes, and reported character cost 20. Scribe v2 received that MP3 **without a language hint** and returned HTTP 200 but detected `ara` (Arabic), confidence **0.985950**, producing Arabic-script transliteration rather than the original Somali. Evidence: `artifacts/voice-probes/so-intake.mp3` and `so-intake.json`.

This longer failure means the issue cannot be dismissed solely as greeting brevity. The synthetic Brian-to-Scribe round trip does not validate Somali speech quality or automatic detection, nor isolate whether synthesis or recognition caused the failure. Native Somali audio and pronunciation review are still needed.

One authorized `GET /v1/shared-voices?language=so` returned HTTP 200 with zero voices (`total_count: 0`, `has_more: false`). This query found no native Somali alternative; it does not prove none exists elsewhere. Evidence: `artifacts/voice-probes/somali-shared-voices.json`. No listing retry was made.


## Alternate Somali voices

Two additional candidates from the same official Somali public page were tested once each with the identical longer Somali text, `eleven_v3` plus `language_code: so`, then Scribe v2 without a hint. Both TTS and STT returned HTTP 200 for each candidate.

| Candidate | Public voice ID | Scribe detection | Confidence | Result |
| --- | --- | --- | --- | --- |
| Jessica | `cgSgspJ2msm6clMCkdW9` | `ara` | 0.957785 | Arabic-script transliteration; failed |
| Alice | `Xb7hH8MSUJpSbSDYk0k2` | `nld` | 0.111221 | Recognizable Somali transcript, but wrong low-confidence detection; failed |

Alice's transcript was “Waxaana ku faqayay laba macluud waxaan donaayaa inaan ka hadlo qalamadaha aan dareemayo”. This resembles the original Somali more closely than the Brian/Jessica transcriptions, but neither candidate satisfied the required Somali detection confidence of at least 0.65. No validated replacement is selected. Artifacts: `artifacts/voice-probes/so-intake-{jessica,alice}.mp3` and corresponding `.json` files. Each generation reported character cost 20. No further candidate retries were made.
