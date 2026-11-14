# Edge-Care demo video

A 90-second Remotion composition follows the six story beats in the project brief with AstraZeneca brand colors and restrained Apple-style typography. The composition needs no external service to render. Rendering requires a compatible Remotion host (including glibc 2.35+ on Linux); the supplied glibc 2.31 host cannot verify the video renderer. Its default frames are explicitly labeled an illustrated storyboard; no simulated UI is passed off as recorded application footage.

```sh
pnpm demo:studio
pnpm demo:render
```

The first render may download Chrome Headless Shell. To use an existing browser, pass `--browser-executable /absolute/path/to/chrome` to the Remotion command. Output is ignored under `demo/remotion/out/`.

After recording the simulator walkthrough, place clips under `public/` and supply composition props:

```sh
pnpm --filter @edgecare/demo-video render --props='{"kioskFootage":"kiosk.mp4","verificationFootage":"verify.mp4","patientFootage":"patient.mp4","voiceover":"voiceover.mp3"}'
```

Optional ElevenLabs narration uses the reviewed synthetic narration text, never health data:

```sh
# Set ELEVENLABS_API_KEY and ELEVENLABS_VOICE_ID in your shell, then:
node scripts/generate-voiceover.mjs
```

No external voice request runs automatically. Review narration length and align the footage when producing the final pitch. The documentary claim is attributed on-screen to [LSV](https://lsv.fi/en/healthcare-for-undocumented-migrants/); eligibility claims were updated from the older brief rather than promising free or guaranteed care.
