# Edge–Care production trailer — V4

The approved 1920×1080, 30 fps trailer, composition `EdgeCareTrailerV4`.
Runtime: **1:56.5**, with a **2:05 hard cap** enforced during rendering and export verification.

## Rebuild

Requirements: Node.js 22.11+, pnpm 9.15.9, Python 3, and `ffmpeg`/`ffprobe` on PATH.
Run from the repository root:

```sh
pnpm install --frozen-lockfile
pnpm --filter @edgecare/demo-video trailer:prepare
pnpm --filter @edgecare/demo-video trailer:studio
pnpm --filter @edgecare/demo-video trailer:preview
pnpm --filter @edgecare/demo-video trailer:render
```

Preparation extracts consecutive JPEGs from all committed MP4s and checks their
counts against `frames.json`. Generated frames and `out/` are ignored by Git.
Remotion downloads Chrome Headless Shell when needed. Set
`REMOTION_BROWSER_EXECUTABLE` to an absolute Chrome path for preview/render
with an existing browser; Studio accepts `--browser-executable`.

The final export is `out/EdgeCare-Trailer-V4-1080p.mp4`. Finalization normalizes
audio to −16 LUFS / −1.5 dBTP, checks codecs, resolution and runtime, performs a
full decode, and writes `out/verification.json`. The checked-in
`verification.json` records the original delivered V4 export.

## Editing and narration

`src/index.tsx` contains the composition, scene durations and dialogue captions.
`captions.json` contains aligned narration captions. Regenerate the companion
SRT and timeline after editing:

```sh
pnpm --filter @edgecare/demo-video trailer:subtitles
```

All required audio is committed. Optional `generate-narration.py` and
`align-narration.py` reuse existing files; generating missing narration or
alignment requires `ELEVENLABS_API_KEY` in the environment. They use Python's
standard library and ElevenLabs APIs. Remove only the relevant audio/alignment
file when deliberately regenerating a line, then regenerate captions/subtitles
and review scene timings.

## Approved cut and provenance

- Shortened kiosk exchange followed by the actual app's symptom summary and
  clinician-review guidance. The synthetic case returned risk band `high` and
  workflow priority score `75`, with the message: “Arrange a clinician review
  for a new or changing lump, mole, unexplained bleeding or symptoms that
  persist or worsen. This guidance cannot diagnose or rule out cancer.”
  The overlay and narration explain the high-priority referral; the score is
  not displayed and is not a disease probability.
- Full doctor-office dialogue, recorded iOS UI, generated actor voices and
  genuine service responses. Kiosk dialogue uses Gemini; doctor translation
  uses ElevenLabs. Captures use synthetic demo cases.
- The complete user-supplied 15.8-second twin tour is preserved byte-for-byte
  as `public/tour-full.mp4`, at normal speed with narration.
- `scope-verification.json` records the original V3/V4 source and media
  comparisons. The opening, physical kiosk, research, handoff, doctor and
  closing sections were preserved.
- Source MP4s contain moving app recordings. The physical kiosk placement is
  a labeled composite/proposal. Library backdrop: **Alfons Morales / Unsplash**,
  https://images.unsplash.com/photo-1507842217343-583bb7270b66.
- Statistical definitions and source links: [`research/SOURCES.md`](research/SOURCES.md).
  Supporting API responses and narration alignment are included in `research/`.

Credits: Terry Huang, Lissan Koirala, Oleg Kaska and Kridhay Mahesh.
AstraZeneca-inspired colors and vision; the closing identifies this as a
hackathon project, not an AstraZeneca product or endorsement.
