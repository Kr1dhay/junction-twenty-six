import test from "node:test";
import assert from "node:assert/strict";
import type { CreateAuthTokenConfig } from "@google/genai";
import { createLiveSession, liveConnectConfig, liveProfileUpdateSchema, liveSessionRequestSchema, voiceEngine } from "../src/server/gemini-live";
import { POST } from "../src/app/demo/voice/live/session/route";
import { GET } from "../src/app/demo/voice/config/route";

const config = { enabled: true, key: "server-only-google-key", model: "gemini-3.8-live", voice: "Kore" };
const profile = { concern_english: "Cough", symptoms_english: ["Cough"], duration_english: "Two days", additional_context_english: "" };

test("Live tokens are short-lived, single-use and constrained to native audio and the English profile tool", async () => {
  let captured: CreateAuthTokenConfig | undefined;
  const before = Date.now();
  const result = await createLiveSession({ consent: true, language: "fi", profile }, config, async (key, options) => {
    assert.equal(key, config.key); captured = options; return { name: "auth_tokens/synthetic-ephemeral" };
  });
  assert.equal(captured?.uses, 1);
  assert.ok(Date.parse(captured!.expireTime!) - before <= 301_000);
  assert.ok(Date.parse(captured!.newSessionExpireTime!) - before <= 61_000);
  assert.equal(captured?.liveConnectConstraints?.model, "gemini-3.8-live");
  assert.equal(result.token, "auth_tokens/synthetic-ephemeral");
  assert.equal(JSON.stringify(result).includes(config.key), false);
  const { setup } = JSON.parse(result.setup_json);
  assert.deepEqual(setup.generationConfig.responseModalities, ["AUDIO"]);
  assert.deepEqual(setup.inputAudioTranscription, {});
  assert.deepEqual(setup.outputAudioTranscription, {});
  assert.equal(setup.thinkingConfig, undefined);
  assert.equal(setup.generationConfig.thinkingConfig, undefined);
  assert.equal(setup.generationConfig.speechConfig.languageCode, undefined);
  assert.equal(setup.tools[0].functionDeclarations[0].name, "record_intake_profile");
  assert.equal(setup.tools[0].functionDeclarations[0].behavior, "BLOCKING");
  assert.equal(setup.realtimeInputConfig.automaticActivityDetection.silenceDurationMs, 600);
  assert.ok(setup.systemInstruction.parts[1].text.includes('"previous_profile"'));
  assert.equal(result.max_session_seconds, 300);
  assert.equal(new URL(result.websocket_url).search, "");
});

test("Live rejects missing consent, disabled providers, unsafe models and provider failures without leaking secrets", async () => {
  const neverMint = async () => { assert.fail("No provider call is allowed"); };
  await assert.rejects(createLiveSession({ consent: false } as never, config, neverMint), /consent/);
  await assert.rejects(createLiveSession({ consent: true }, { ...config, enabled: false }, neverMint), /not configured/);
  await assert.rejects(createLiveSession({ consent: true }, { ...config, key: undefined }, neverMint), /not configured/);
  await assert.rejects(createLiveSession({ consent: true }, { ...config, model: "gemini-3.8-live-extended-thinking" }, neverMint), /must be gemini-3.8-live/);
  await assert.rejects(createLiveSession({ consent: true }, config, async () => { throw new Error(config.key); }), error => {
    assert.ok(error instanceof Error); assert.equal(error.message.includes(config.key), false); return true;
  });
  await assert.rejects(createLiveSession({ consent: true }, config, async () => ({ name: config.key })), /invalid session credential/);
});

test("Live intake accepts bounded multilingual context and strict English profile fields", () => {
  assert.equal(liveSessionRequestSchema.safeParse({ consent: true, profile, history: [{ role: "user", text: "Minulla on yskää." }] }).success, true);
  for (const body of [{ consent: false }, { consent: true, passcode: "1234" }, { consent: true, history: Array(31).fill({ role: "user", text: "x" }) }]) {
    assert.equal(liveSessionRequestSchema.safeParse(body).success, false);
  }
  assert.equal(liveProfileUpdateSchema.safeParse({ detected_language: "fi", profile, stop_requested: false }).success, true);
  assert.equal(liveProfileUpdateSchema.safeParse({ detected_language: "fi", profile: { ...profile, name: "Forbidden" }, stop_requested: false }).success, false);
  const prompt = JSON.stringify(liveConnectConfig({ consent: true, profile }));
  assert.ok(prompt.includes("early stop"));
  assert.ok(prompt.includes("English"));
});

test("Live configuration and bootstrap retain authentication, same-origin and demo/consent gates", async () => {
  const values = { DEMO_MODE: "true", CHAIN: "mock", LLM: "ondevice", EDGECARE_CLOUD_VOICE: "true",
    EDGECARE_VOICE_ENGINE: "", GEMINI_API_KEY: "synthetic-google-key", EDGECARE_ISSUER_TOKEN: "issuer",
    EDGECARE_CLINICIAN_TOKEN: "clinician", EDGECARE_PUBLIC_ORIGIN: "https://edgecare.example" };
  const previous = Object.fromEntries(Object.keys(values).map(key => [key, process.env[key]]));
  const request = (path: string, body?: unknown, headers = {}) => new Request(`https://edgecare.example${path}`, {
    method: body === undefined ? "GET" : "POST", headers,
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  try {
    Object.assign(process.env, values);
    assert.equal(voiceEngine(), "gemini_live");
    process.env.EDGECARE_VOICE_ENGINE = "legacy"; assert.equal(voiceEngine(), "legacy");
    process.env.EDGECARE_VOICE_ENGINE = "unknown"; assert.throws(voiceEngine);
    process.env.EDGECARE_VOICE_ENGINE = "gemini_live";
    assert.equal((await GET(request("/demo/voice/config"))).status, 401);
    const descriptor = await GET(request("/demo/voice/config", undefined, { authorization: "Bearer issuer" }));
    assert.deepEqual(await descriptor.json(), { engine: "gemini_live" });
    assert.equal(descriptor.headers.get("cache-control"), "no-store");
    assert.equal((await POST(request("/demo/voice/live/session", { consent: true }))).status, 401);
    assert.equal((await POST(request("/demo/voice/live/session", { consent: true }, { authorization: "Bearer issuer", origin: "https://attacker.example" }))).status, 403);
    assert.equal((await POST(request("/demo/voice/live/session", { consent: false }, { authorization: "Bearer issuer" }))).status, 400);
    process.env.EDGECARE_CLOUD_VOICE = "false";
    assert.equal((await POST(request("/demo/voice/live/session", { consent: true }, { authorization: "Bearer issuer" }))).status, 503);
    process.env.DEMO_MODE = "false";
    assert.equal((await GET(request("/demo/voice/config", undefined, { authorization: "Bearer issuer" }))).status, 503);
  } finally {
    for (const key of Object.keys(values)) { if (previous[key] === undefined) delete process.env[key]; else process.env[key] = previous[key]; }
  }
});
