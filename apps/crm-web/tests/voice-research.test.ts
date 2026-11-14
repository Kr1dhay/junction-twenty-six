import test from "node:test";
import assert from "node:assert/strict";
import { demoReferrals } from "@edgecare/shared-types/fixtures";
import { referralSchema, toCRMReferral, voiceResearchAssessmentSchema } from "@edgecare/shared-types";
import { assessResearchVoice, inspectResearchWAV, voiceResearchAvailable, VoiceResearchError, type VoiceResearchConfig } from "../src/server/voice-research";
import { GET, POST } from "../src/app/demo/voice/research/route";

const config: VoiceResearchConfig = {
  enabled: true, url: "https://worker.invalid", token: "synthetic-worker-token",
  modelID: "synthetic-test-only", modelVersion: "test-1",
};
function wav(amplitude = 4000, seconds = 3) {
  const samples = seconds * 16000;
  const out = Buffer.alloc(44 + samples * 2);
  out.write("RIFF", 0); out.writeUInt32LE(out.length - 8, 4); out.write("WAVEfmt ", 8);
  out.writeUInt32LE(16, 16); out.writeUInt16LE(1, 20); out.writeUInt16LE(1, 22);
  out.writeUInt32LE(16000, 24); out.writeUInt32LE(32000, 28); out.writeUInt16LE(2, 32); out.writeUInt16LE(16, 34);
  out.write("data", 36); out.writeUInt32LE(samples * 2, 40);
  for (let i = 0; i < samples; i++) out.writeInt16LE(Math.round(amplitude * Math.sin(2 * Math.PI * 180 * i / 16000)), 44 + i * 2);
  return out;
}
const input = () => ({ consent: true, task: "sustained_a", capture_mode: "measurement", audio_base64: wav().toString("base64") });
const result = {
  outcome: "not_flagged" as const, assessed_at: "2026-11-14T12:00:00.000Z", model_id: "synthetic-test-only",
  model_version: "test-1", sample_duration_seconds: 3, research_only: true as const,
};

test("consent, dedicated task and unprocessed capture are mandatory before any upload", async () => {
  let calls = 0;
  const fetcher: typeof fetch = async () => { calls++; return Response.json(result); };
  for (const bad of [{ ...input(), consent: false }, { ...input(), task: "conversation" },
    { ...input(), capture_mode: "voiceChat" }, { ...input(), name: "not-allowed" }]) {
    await assert.rejects(assessResearchVoice(bad, config, fetcher), (e: unknown) => e instanceof VoiceResearchError && e.status === 400);
  }
  assert.equal(calls, 0);
});

test("missing configuration never fabricates a classification", async () => {
  let calls = 0;
  const fetcher: typeof fetch = async () => { calls++; return Response.json(result); };
  await assert.rejects(assessResearchVoice(input(), { ...config, enabled: false }, fetcher), VoiceResearchError);
  assert.equal(await voiceResearchAvailable({ enabled: false }, fetcher), false);
  assert.equal(calls, 0);
});

test("availability checks exact approved model identity and returns no credentials", async () => {
  assert.equal(await voiceResearchAvailable(config, async () => Response.json({
    ready: true, research_only: true, model_id: config.modelID, model_version: config.modelVersion,
  })), true);
  assert.equal(await voiceResearchAvailable(config, async () => Response.json({
    ready: true, research_only: true, model_id: "wrong-model", model_version: config.modelVersion,
  })), false);
});

test("consented audio goes only to the configured worker and schema-validated result is retained", async () => {
  let sent: unknown;
  const actual = await assessResearchVoice(input(), config, async (url, options) => {
    assert.equal(String(url), "https://worker.invalid/assess");
    assert.equal((options!.headers as Record<string, string>).authorization, "Bearer synthetic-worker-token");
    assert.equal(options!.redirect, "error");
    sent = JSON.parse(options!.body as string);
    return Response.json(result);
  });
  assert.deepEqual(sent, input());
  assert.deepEqual(actual, result);
  assert.equal(JSON.stringify(actual).includes("synthetic-worker-token"), false);
  assert.equal(JSON.stringify(actual).includes("audio_base64"), false);
});

test("quiet, clipped and malformed recordings abstain or reject without calling a classifier", async () => {
  let calls = 0;
  const fetcher: typeof fetch = async () => { calls++; return Response.json(result); };
  const quiet = await assessResearchVoice({ ...input(), audio_base64: wav(0).toString("base64") }, config, fetcher);
  assert.equal(quiet.outcome, "inconclusive");
  const clipped = wav();
  for (let n = 44; n < clipped.length; n += 2) clipped.writeInt16LE(32767, n);
  assert.equal((await assessResearchVoice({ ...input(), audio_base64: clipped.toString("base64") }, config, fetcher)).outcome, "inconclusive");
  for (const audio of [Buffer.from("fake-wav"), wav(4000, 1), wav(4000, 13)]) {
    await assert.rejects(assessResearchVoice({ ...input(), audio_base64: audio.toString("base64") }, config, fetcher), VoiceResearchError);
  }
  assert.equal(calls, 0);
});

test("PCM shape, declared lengths and sample rate must match the recording contract", () => {
  assert.equal(inspectResearchWAV(wav()).duration, 3);
  const wrongRate = wav(); wrongRate.writeUInt32LE(48000, 24);
  assert.throws(() => inspectResearchWAV(wrongRate), VoiceResearchError);
  const truncated = wav().subarray(0, 100);
  assert.throws(() => inspectResearchWAV(truncated), VoiceResearchError);
});

test("diagnostic labels, probabilities, mismatched models and provider errors are not accepted", async () => {
  for (const body of [{ ...result, outcome: "cancer" }, { ...result, probability: 0.98 },
    { ...result, research_only: false }, { ...result, model_id: "wrong" },
    { ...result, sample_duration_seconds: 8 }]) {
    await assert.rejects(assessResearchVoice(input(), config, async () => Response.json(body)),
      (e: unknown) => e instanceof VoiceResearchError && e.status === 503);
  }
  await assert.rejects(assessResearchVoice(input(), config, async () => new Response("secret provider error", { status: 500 })), VoiceResearchError);
});

test("redirects and non-HTTPS external worker configuration fail closed", async () => {
  let calls = 0;
  for (const url of ["http://external.invalid", "https://user:password@worker.invalid", "https://worker.invalid?token=unsafe"]) {
    await assert.rejects(assessResearchVoice(input(), { ...config, url }, async () => {
      calls++; return Response.json(result);
    }), VoiceResearchError);
  }
  assert.equal(calls, 0);
});

test("legacy referral compatibility and clinician projection preserve research without changing risk", () => {
  assert.equal(referralSchema.safeParse(demoReferrals[0]).success, true);
  const record = referralSchema.parse({ ...demoReferrals[0], voice_research: result });
  const crm = toCRMReferral(record);
  assert.deepEqual(crm.voice_research, result);
  assert.equal(crm.risk_score, demoReferrals[0]!.risk_score);
  assert.equal(crm.recommended_specialty, demoReferrals[0]!.recommended_specialty);
  assert.equal(voiceResearchAssessmentSchema.safeParse({ ...result, raw_audio: "forbidden" }).success, false);
});

test("routes require authorized access and refuse unsupported/unconsented requests", async () => {
  const keys = ["DEMO_MODE", "CHAIN", "LLM", "EDGECARE_ISSUER_TOKEN", "EDGECARE_CLINICIAN_TOKEN", "EDGECARE_VOICE_RESEARCH"] as const;
  const saved = Object.fromEntries(keys.map(key => [key, process.env[key]]));
  try {
    Object.assign(process.env, { DEMO_MODE: "true", CHAIN: "mock", LLM: "ondevice",
      EDGECARE_ISSUER_TOKEN: "synthetic-issuer", EDGECARE_CLINICIAN_TOKEN: "synthetic-clinician", EDGECARE_VOICE_RESEARCH: "false" });
    const request = (body?: unknown, authorized = true) => new Request("http://localhost/demo/voice/research", {
      method: body === undefined ? "GET" : "POST",
      headers: authorized ? { authorization: "Bearer synthetic-issuer" } : {},
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    assert.equal((await GET(request(undefined, false))).status, 401);
    assert.equal((await POST(request(input(), false))).status, 401);
    assert.deepEqual(await (await GET(request())).json(), { available: false });
    assert.equal((await POST(request({ ...input(), consent: false }))).status, 400);
    const unavailable = await POST(request(input()));
    assert.equal(unavailable.status, 503);
    assert.equal(JSON.stringify(await unavailable.json()).includes("synthetic-"), false);
  } finally {
    for (const key of keys) { if (saved[key] === undefined) delete process.env[key]; else process.env[key] = saved[key]; }
  }
});
