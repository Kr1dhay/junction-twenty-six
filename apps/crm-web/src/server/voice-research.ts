import { z } from "zod";
import { voiceResearchAssessmentSchema, voiceResearchRequestSchema, type VoiceResearchAssessment } from "@edgecare/shared-types";
import { readJSON } from "./http";

export class VoiceResearchError extends Error {
  constructor(readonly status: number) { super("Research voice analysis could not complete. Continue with clinician review."); }
}
export interface VoiceResearchConfig {
  enabled: boolean;
  url?: string;
  token?: string;
  modelID?: string;
  modelVersion?: string;
}
export function voiceResearchConfig(): VoiceResearchConfig {
  return {
    enabled: process.env.EDGECARE_VOICE_RESEARCH === "true",
    url: process.env.VOICE_RESEARCH_URL, token: process.env.VOICE_RESEARCH_TOKEN,
    modelID: process.env.VOICE_RESEARCH_MODEL_ID, modelVersion: process.env.VOICE_RESEARCH_MODEL_VERSION,
  };
}
function configured(config: VoiceResearchConfig): URL {
  if (!config.enabled || !config.url || !config.token || !config.modelID || !config.modelVersion) throw new VoiceResearchError(503);
  let url: URL;
  try { url = new URL(config.url); } catch { throw new VoiceResearchError(503); }
  const loopback = ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname);
  if ((url.protocol !== "https:" && !(loopback && url.protocol === "http:")) ||
      url.username || url.password || url.search || url.hash || !["", "/"].includes(url.pathname)) throw new VoiceResearchError(503);
  return url;
}
const identitySchema = z.object({
  ready: z.literal(true), research_only: z.literal(true),
  model_id: z.string().min(1).max(120), model_version: z.string().min(1).max(120),
}).strict();
export async function voiceResearchAvailable(config = voiceResearchConfig(), fetcher: typeof fetch = fetch): Promise<boolean> {
  try {
    const url = configured(config);
    const response = await fetcher(new URL("/health", url), {
      headers: { authorization: `Bearer ${config.token}` }, cache: "no-store", redirect: "error", signal: AbortSignal.timeout(3000),
    });
    if (!response.ok) return false;
    const identity = identitySchema.parse(await readJSON(response, 4096));
    return identity.model_id === config.modelID && identity.model_version === config.modelVersion;
  } catch { return false; }
}

/** Accept only bounded, mono, 16-bit PCM WAV at 16 kHz, never consultation audio. */
export function inspectResearchWAV(audio: Buffer): { duration: number; adequate: boolean } {
  if (audio.length < 44 || audio.length > 512 * 1024 ||
      audio.toString("ascii", 0, 4) !== "RIFF" || audio.toString("ascii", 8, 12) !== "WAVE" ||
      audio.readUInt32LE(4) !== audio.length - 8) throw new VoiceResearchError(400);
  let format = false;
  let pcm: Buffer | undefined;
  let offset = 12;
  while (offset + 8 <= audio.length) {
    const name = audio.toString("ascii", offset, offset + 4);
    const size = audio.readUInt32LE(offset + 4);
    const start = offset + 8;
    if (start + size > audio.length) throw new VoiceResearchError(400);
    if (name === "fmt ") {
      if (format || size < 16 || audio.readUInt16LE(start) !== 1 || audio.readUInt16LE(start + 2) !== 1 ||
          audio.readUInt32LE(start + 4) !== 16000 || audio.readUInt32LE(start + 8) !== 32000 ||
          audio.readUInt16LE(start + 12) !== 2 || audio.readUInt16LE(start + 14) !== 16) throw new VoiceResearchError(400);
      format = true;
    }
    if (name === "data") {
      if (pcm || size % 2) throw new VoiceResearchError(400);
      pcm = audio.subarray(start, start + size);
    }
    offset = start + size + size % 2;
  }
  if (!format || !pcm || offset !== audio.length) throw new VoiceResearchError(400);
  const duration = pcm.length / 32000;
  if (duration < 2 || duration > 12) throw new VoiceResearchError(400);
  let sum = 0; let clipped = 0;
  for (let i = 0; i < pcm.length; i += 2) {
    const sample = pcm.readInt16LE(i) / 32768;
    sum += sample * sample; if (Math.abs(sample) >= 0.999) clipped++;
  }
  const count = pcm.length / 2;
  return { duration, adequate: Math.sqrt(sum / count) >= 0.006 && clipped / count < 0.01 };
}

export async function assessResearchVoice(input: unknown, config = voiceResearchConfig(), fetcher: typeof fetch = fetch): Promise<VoiceResearchAssessment> {
  const parsed = voiceResearchRequestSchema.safeParse(input);
  if (!parsed.success) throw new VoiceResearchError(400);
  const url = configured(config);
  const audio = Buffer.from(parsed.data.audio_base64, "base64");
  const quality = inspectResearchWAV(audio);
  // Quiet/clipped samples abstain without ever contacting the classifier.
  if (!quality.adequate) return voiceResearchAssessmentSchema.parse({
    outcome: "inconclusive", assessed_at: new Date().toISOString(), model_id: "recording-quality",
    model_version: "1", sample_duration_seconds: quality.duration, research_only: true,
  });
  try {
    const response = await fetcher(new URL("/assess", url), {
      method: "POST", headers: { authorization: `Bearer ${config.token}`, "content-type": "application/json" },
      body: JSON.stringify(parsed.data), cache: "no-store", redirect: "error", signal: AbortSignal.timeout(30000),
    });
    if (!response.ok) throw new VoiceResearchError(503);
    const result = voiceResearchAssessmentSchema.parse(await readJSON(response, 8192));
    if (result.model_id !== config.modelID || result.model_version !== config.modelVersion ||
        Math.abs(result.sample_duration_seconds - quality.duration) > 0.02) throw new VoiceResearchError(503);
    return result;
  } catch { throw new VoiceResearchError(503); }
}
