import { readFile, mkdir, writeFile } from 'node:fs/promises';
const key = process.env.ELEVENLABS_API_KEY;
const voice = process.env.ELEVENLABS_VOICE_ID;
if (!key || !voice) throw new Error('Set ELEVENLABS_API_KEY and ELEVENLABS_VOICE_ID to generate the demo narration.');
const text = await readFile(new URL('../demo/remotion/voiceover.txt', import.meta.url), 'utf8');
const response = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(voice)}?output_format=mp3_44100_128`, {
  method: 'POST', headers: { 'xi-api-key': key, 'Content-Type': 'application/json' },
  body: JSON.stringify({ text, model_id: process.env.ELEVENLABS_MODEL_ID ?? 'eleven_multilingual_v2' }),
  signal: AbortSignal.timeout(120000),
});
if (!response.ok) throw new Error(`Voice generation failed (${response.status}). No credentials or response body were logged.`);
const output = new URL('../demo/remotion/public/voiceover.mp3', import.meta.url);
await mkdir(new URL('../demo/remotion/public/', import.meta.url), { recursive: true });
await writeFile(output, Buffer.from(await response.arrayBuffer()));
console.log('Saved demo/remotion/public/voiceover.mp3. Pass --props=\'{"voiceover":"voiceover.mp3"}\' to Remotion.');
