import test from "node:test";
import assert from "node:assert/strict";
import { runVoiceTurn, VoiceError, type VoiceConfig } from "../src/server/voice";
import { voiceTurnRequestSchema, type VoiceTurnRequest } from "@edgecare/shared-types";
import { POST } from "../src/app/demo/voice/turn/route";
const config: VoiceConfig = { enabled: true, geminiKey: "gemini-test-secret", geminiModel: "configured-gemini-model", elevenKey: "eleven-test-secret", voiceID: "selected-demo-voice", sttModel: "scribe_v2", ttsModel: "eleven_v3", zeroRetention: false };
const profile = { concern_english: "A changing skin mark", symptoms_english: ["Skin change"], duration_english: "Two weeks", additional_context_english: "The patient requests clinician review." };
const generated = (language = "so") => ({ detected_language: language, reply: "Waad mahadsan tahay. Waan diiwaangeliyey xogtaada.", profile, intake_complete: true, stop_requested: false });
const geminiResponse = (value = generated()) => Response.json({ candidates: [{ content: { parts: [{ text: JSON.stringify(value) }] } }] });
const audio: VoiceTurnRequest = { consent: true, audio_base64: Buffer.from("synthetic-audio-bytes").toString("base64"), audio_mime_type: "audio/mp4", language: "en", profile, history: [{ role: "assistant", text: "How can I help?" }] };

test("Ukrainian detection selects the Ukrainian voice and closing", async () => {
  let calls = 0;
  const fetcher: typeof fetch = async (url, init) => {
    calls++;
    if (calls === 1) return Response.json({ text: "У мене кашель уже два дні.", language_code: "ukr", language_probability: 0.99 });
    if (calls === 2) return geminiResponse({ ...generated("uk"), reply: "Що ще?" });
    assert.ok(String(url).includes("selected-ukrainian-voice"));
    assert.equal(JSON.parse(init!.body as string).language_code, "uk");
    return new Response(Buffer.from("synthetic-mp3"), { headers: { "Content-Type": "audio/mpeg" } });
  };
  const result = await runVoiceTurn(audio, { ...config, voices: { uk: "selected-ukrainian-voice" } }, fetcher);
  assert.equal(result.detected_language, "uk");
  assert.equal(result.reply, "Дякую. Надану вами інформацію записано.");
  assert.equal(result.speech_available, true);
});

test("spoken language is detected automatically and Gemini maintains an English profile before configured-voice TTS", async () => {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetcher: typeof fetch = async (url, init) => {
    calls.push({ url: String(url), init: init! });
    if (calls.length === 1) return Response.json({ text: "Bar baa is beddelay.", language_code: "som", language_probability: 0.99 });
    if (calls.length === 2) return geminiResponse();
    return new Response(Buffer.from("synthetic-mp3"), { headers: { "Content-Type": "audio/mpeg" } });
  };
  const result = await runVoiceTurn(audio, { ...config, voices: { so: "selected-somali-voice" } }, fetcher);
  assert.equal(calls.length, 3);
  const form = calls[0]!.init.body as FormData;
  assert.equal(form.get("language_code"), null);
  assert.equal(form.get("model_id"), "scribe_v2");
  assert.equal(calls[0]!.url.includes("enable_logging"), false);
  const gemini = JSON.parse(calls[1]!.init.body as string);
  assert.equal(gemini.generationConfig.responseMimeType, "application/json");
  assert.deepEqual(JSON.parse(gemini.contents[0].parts[0].text).previous_profile, profile);
  assert.ok(gemini.systemInstruction.parts[0].text.includes("ALWAYS contain English"));
  assert.equal(result.detected_language, "so");
  assert.deepEqual(result.profile, profile);
  assert.equal(result.speech_available, true);
  assert.equal(result.audio_mime_type, "audio/mpeg");
  assert.equal(calls[2]!.url.includes("selected-somali-voice"), true);
  assert.equal(JSON.parse(calls[2]!.init.body as string).language_code, "so");
  assert.equal(JSON.stringify(result).includes("secret"), false);
});

test("typed turns bypass STT; normalization uses Gemini only and never generates audio", async () => {
  let count = 0;
  const fetcher: typeof fetch = async url => { count++; assert.ok(String(url).includes("generativelanguage.googleapis.com")); return geminiResponse(generated("fi")); };
  const result = await runVoiceTurn({ consent: true, text: "Ihossa on muutos", language: "fi" }, config, fetcher, undefined, false);
  assert.equal(count, 1); assert.equal(result.detected_language, "fi"); assert.equal(result.audio_base64, null);
});

test("low-confidence STT asks for clarification without sending a transcript to Gemini", async () => {
  let count = 0;
  await assert.rejects(runVoiceTurn(audio, config, async () => { count++; return Response.json({ text: "unclear", language_code: "en", language_probability: 0.3 }); }), (error: unknown) => error instanceof VoiceError && error.status === 422);
  assert.equal(count, 1);
});

test("missing configuration, absent consent and provider failure never fabricate success", async () => {
  const forbiddenFetch: typeof fetch = async () => { throw new Error("Must not contact network"); };
  await assert.rejects(runVoiceTurn(audio, { ...config, enabled: false }, forbiddenFetch), /disabled/);
  await assert.rejects(runVoiceTurn(audio, { ...config, geminiKey: undefined }, forbiddenFetch), /not configured/);
  await assert.rejects(runVoiceTurn({ ...audio, consent: false } as unknown as VoiceTurnRequest, config, forbiddenFetch), /consent/);
  await assert.rejects(runVoiceTurn(audio, config, async () => new Response("provider secret detailed error", { status: 403 })), error => error instanceof VoiceError && !error.message.includes("secret"));
  assert.equal(voiceTurnRequestSchema.safeParse({ text: "hello", consent: false }).success, false);
  assert.equal(voiceTurnRequestSchema.safeParse({ ...audio, text: "hello" }).success, false);
  assert.equal(voiceTurnRequestSchema.safeParse({ ...audio, passcode: "1234" }).success, false);
});

test("unsupported speech and TTS failures preserve text/profile with explicit speech unavailable", async () => {
  let count = 0;
  const result = await runVoiceTurn({ consent: true, text: "A concern", language: "so" }, { ...config, ttsModel: "eleven_multilingual_v2" }, async () => { count++; return geminiResponse(); });
  assert.equal(count, 1); assert.equal(result.speech_available, false); assert.equal(result.audio_base64, null); assert.match(result.speech_error!, /does not support/); assert.deepEqual(result.profile, profile);
  count = 0;
  const failedSpeech = await runVoiceTurn({ consent: true, text: "A concern" }, config, async () => ++count === 1 ? geminiResponse() : new Response("No speech", { status: 503 }));
  assert.equal(failedSpeech.speech_available, false); assert.deepEqual(failedSpeech.profile, profile); assert.match(failedSpeech.speech_error!, /unavailable/);
});

test("malformed model output and wrong response language are rejected", async () => {
  await assert.rejects(runVoiceTurn({ consent: true, text: "hello" }, config, async () => geminiResponse({ ...generated(), profile: { ...profile, patient_name: "Forbidden" } } as never)), /invalid profile/);
  let count = 0;
  await assert.rejects(runVoiceTurn(audio, config, async () => ++count === 1 ? Response.json({ text: "Somali input", language_code: "so", language_probability: 0.99 }) : geminiResponse(generated("en"))), /did not match/);
});

test("voice route validates consent and returns unavailable with no configured live credentials", async () => {
  process.env.DEMO_MODE = "true"; process.env.CHAIN = "mock"; process.env.LLM = "ondevice";
  delete process.env.EDGECARE_CLOUD_VOICE;
  const request = (body: unknown) => new Request("http://localhost/demo/voice/turn", { method: "POST", body: JSON.stringify(body) });
  assert.equal((await POST(request({ text: "hello", consent: false }))).status, 400);
  assert.equal((await POST(request({ text: "hello", consent: true }))).status, 503);
});

const runwareConfig: VoiceConfig = { ...config, provider: "runware", runwareKey: "runware-test-secret", runwareModel: "google:gemini@3.1-pro", geminiKey: undefined, geminiModel: undefined };
const runwareResponse = (value: unknown = generated("fi"), finish_reason = "tool_calls") => Response.json({ choices: [{ finish_reason, message: { tool_calls: [{ type: "function", function: { name: "record_intake_turn", arguments: JSON.stringify(value) } }], refusal: null } }] });

test("Runware uses the configured Gemini text model and structured schema with server-side credentials", async () => {
  const result = await runVoiceTurn({ consent: true, text: "Ihossa on muutos", profile, history: audio.history }, runwareConfig, async (url, init) => {
    assert.equal(String(url), "https://api.runware.ai/v1/chat/completions");
    assert.equal((init!.headers as Record<string, string>).Authorization, "Bearer runware-test-secret");
    assert.equal(init!.cache, "no-store");
    const body = JSON.parse(init!.body as string);
    assert.equal(body.model, "google:gemini@3.1-pro");
    assert.equal(body.tool_choice.function.name, "record_intake_turn");
    assert.equal(body.parallel_tool_calls, false);
    assert.equal(body.tools[0].function.strict, true);
    assert.equal(body.tools[0].function.parameters.additionalProperties, false);
    assert.equal(body.tools[0].function.parameters.properties.profile.additionalProperties, false);
    assert.match(body.messages[0].content, /ALWAYS contain English/);
    assert.deepEqual(JSON.parse(body.messages[1].content).previous_profile, profile);
    assert.deepEqual(JSON.parse(body.messages[1].content).conversation_history, audio.history);
    return runwareResponse();
  }, undefined, false);
  assert.equal(result.detected_language, "fi");
  assert.deepEqual(result.profile, profile);
  assert.equal(JSON.stringify(result).includes("secret"), false);
});

test("Runware rejects missing credentials, non-Gemini models and auto routing without fallback", async () => {
  const forbiddenFetch: typeof fetch = async () => { throw new Error("Must not contact network"); };
  for (const overrides of [{ runwareKey: undefined }, { runwareModel: undefined }, { runwareModel: "auto" }, { runwareModel: "google:4@1" }, { runwareModel: "openai:gpt@5.5" }]) {
    await assert.rejects(runVoiceTurn({ consent: true, text: "hello" }, { ...runwareConfig, ...overrides, geminiKey: "available-direct-key" }, forbiddenFetch), error => error instanceof VoiceError && error.status === 503);
  }
});

test("Runware errors, refusals, truncated output and invalid profiles cannot fabricate a turn", async () => {
  for (const response of [new Response("provider-secret", { status: 403 }), runwareResponse(generated(), "length"), Response.json({ choices: [{ finish_reason: "stop", message: { content: null, refusal: "refused" } }] }), runwareResponse({ ...generated(), profile: { ...profile, patient_name: "Forbidden" } }), Response.json({ data: [{ text: "not a chat completion" }] })]) {
    let count = 0;
    await assert.rejects(runVoiceTurn({ consent: true, text: "hello", profile }, runwareConfig, async () => { count++; return response; }, undefined, false), error => error instanceof VoiceError && !error.message.includes("secret"));
    assert.equal(count, 1);
  }
});

test("Runware preserves externally detected speech language validation", async () => {
  let count = 0;
  await assert.rejects(runVoiceTurn(audio, runwareConfig, async () => ++count === 1 ? Response.json({ text: "Somali input", language_code: "so", language_probability: 0.99 }) : runwareResponse(generated("en"))), /did not match/);
  assert.equal(count, 2);
});

test("Runware accepts only the single named structured call, never JSON scraped from prose", async () => {
  const validTool = { type: "function", function: { name: "record_intake_turn", arguments: JSON.stringify(generated("en")) } };
  const response = (tool_calls: unknown[], content = "ignored provider reasoning") => Response.json({ choices: [{ finish_reason: "tool_calls", message: { tool_calls, content } }] });
  const result = await runVoiceTurn({ consent: true, text: "hello" }, runwareConfig, async () => response([validTool]), undefined, false);
  assert.deepEqual(result.profile, profile);
  assert.equal(JSON.stringify(result).includes("reasoning"), false);
  for (const tools of [[], [validTool, validTool], [{ ...validTool, function: { ...validTool.function, name: "other_tool" } }], [{ ...validTool, function: { ...validTool.function, arguments: `Explanation: ${validTool.function.arguments}` } }]]) {
    await assert.rejects(runVoiceTurn({ consent: true, text: "hello" }, runwareConfig, async () => response(tools, JSON.stringify(generated())), undefined, false), /invalid profile/);
  }
});


test("completion follows essential answers across turns and corrections, without optional questioning", async () => {
  const firstProfile = { ...profile, duration_english: "", additional_context_english: "" };
  const first = await runVoiceTurn({ consent: true, text: "A changing skin mark" }, config,
    async () => geminiResponse({ ...generated("en"), profile: firstProfile, intake_complete: true, reply: "How long has it been changing?" }), undefined, false);
  assert.equal(first.intake_complete, false);
  assert.equal(first.profile.duration_english, "");
  assert.equal(first.reply, "How long has it been changing?");
  const completeProfile = { ...firstProfile, duration_english: "Two weeks" };
  const second = await runVoiceTurn({ consent: true, text: "Two weeks", profile: first.profile }, config,
    async () => geminiResponse({ ...generated("en"), profile: completeProfile, intake_complete: false, reply: "Thank you. Anything else?" }), undefined, false);
  assert.equal(second.intake_complete, true);
  assert.doesNotMatch(second.reply, /[?؟？]/u);
  assert.match(second.reply, /recorded your intake/);
  assert.equal(second.profile.additional_context_english, "");
  const corrected = await runVoiceTurn({ consent: true, text: "Actually I do not know how long", profile: second.profile }, config,
    async () => geminiResponse({ ...generated("en"), profile: { ...completeProfile, duration_english: "Patient does not know the duration" } }), undefined, false);
  assert.equal(corrected.intake_complete, true);
  assert.equal(corrected.profile.duration_english, "Patient does not know the duration");
  const cleared = await runVoiceTurn({ consent: true, text: "That duration was incorrect", profile: second.profile }, config,
    async () => geminiResponse({ ...generated("en"), profile: firstProfile }), undefined, false);
  assert.equal(cleared.intake_complete, false);
});

test("missing essentials never complete or get filled by the server", async () => {
  for (const missing of [{ concern_english: " " }, { symptoms_english: [] }, { symptoms_english: [" "] }, { duration_english: " " }]) {
    const partial = { ...profile, ...missing };
    const result = await runVoiceTurn({ consent: true, text: "I have a concern" }, runwareConfig,
      async () => runwareResponse({ ...generated("en"), profile: partial, intake_complete: true }), undefined, false);
    assert.equal(result.intake_complete, false);
    assert.deepEqual(result.profile, partial);
  }
});

test("completed localized turns retain urgent instructions and omit residual questions", async () => {
  for (const [language, reply, safety] of [
    ["en", "Seek urgent local medical help now. How long has this happened?", "Seek urgent local medical help now."],
    ["ar", "اطلب المساعدة الطبية العاجلة الآن. منذ متى؟", "اطلب المساعدة الطبية العاجلة الآن."],
    ["fi", "Hakeudu heti päivystykseen. Onko muuta?", "Hakeudu heti päivystykseen."],
    ["so", "Raadi gargaar caafimaad degdeg ah hadda. Wax kale?", "Raadi gargaar caafimaad degdeg ah hadda."],
    ["uk", "Негайно зверніться по медичну допомогу. Що ще?", "Негайно зверніться по медичну допомогу."],
  ]) {
    const result = await runVoiceTurn({ consent: true, text: "Synthetic concern" }, config,
      async () => geminiResponse({ ...generated(language), reply: reply! }), undefined, false);
    assert.equal(result.intake_complete, true);
    assert.ok(result.reply.includes(safety!));
    assert.doesNotMatch(result.reply, /[?؟？]/u);
  }
});

test("both providers require a strict completion boolean and instructions forbid inferred answers", async () => {
  for (const provider of [config, runwareConfig]) {
    await runVoiceTurn({ consent: true, text: "Synthetic concern" }, provider, async (_url, init) => {
      const body = JSON.parse(init!.body as string);
      const schema = provider.provider === "runware" ? body.tools[0].function.parameters : body.generationConfig.responseJsonSchema;
      const prompt = provider.provider === "runware" ? body.messages[0].content : body.systemInstruction.parts[0].text;
      assert.equal(schema.properties.intake_complete.type, "boolean");
      assert.ok(schema.required.includes("intake_complete"));
      assert.equal(schema.properties.stop_requested.type, "boolean");
      assert.ok(schema.required.includes("stop_requested"));
      assert.match(prompt, /never infer an unknown answer from silence/);
      assert.match(prompt, /never as a routine extra question/);
      assert.match(prompt, /explicit request to stop must be respected/);
      return provider.provider === "runware" ? runwareResponse() : geminiResponse();
    }, undefined, false);
    for (const field of ["intake_complete", "stop_requested"]) for (const invalid of [undefined, "true", 1, null]) {
      const value = { ...generated(), [field]: invalid };
      await assert.rejects(runVoiceTurn({ consent: true, text: "Synthetic concern" }, provider,
        async () => provider.provider === "runware" ? runwareResponse(value) : geminiResponse(value as never), undefined, false), /invalid profile/);
    }
  }
});


test("explicit stop ends conversation without completing or inventing missing essentials", async () => {
  const incomplete = { ...profile, symptoms_english: [], duration_english: "" };
  for (const provider of [config, runwareConfig]) {
    const value = { ...generated("en"), stop_requested: true, intake_complete: false, profile: incomplete, reply: "How long has this lasted?" };
    const result = await runVoiceTurn({ consent: true, text: "Please stop now", profile: incomplete }, provider,
      async () => provider.provider === "runware" ? runwareResponse(value) : geminiResponse(value), undefined, false);
    assert.equal(result.conversation_ended, true);
    assert.equal(result.intake_complete, false);
    assert.deepEqual(result.profile, incomplete);
    assert.equal(result.reply, "We will stop here.");
    const continuing = { ...value, stop_requested: false };
    const next = await runVoiceTurn({ consent: true, text: "Continue", profile: incomplete }, provider,
      async () => provider.provider === "runware" ? runwareResponse(continuing) : geminiResponse(continuing), undefined, false);
    assert.equal(next.conversation_ended, false);
  }
});

test("unsupported closing languages never return a question or substitute English", async () => {
  const safe = await runVoiceTurn({ consent: true, text: "Une toux depuis deux jours" }, config,
    async () => geminiResponse({ ...generated("fr"), reply: "Merci. Autre chose?" }), undefined, false);
  assert.equal(safe.conversation_ended, true);
  assert.equal(safe.reply, "Merci.");
  await assert.rejects(runVoiceTurn({ consent: true, text: "Une toux depuis deux jours" }, config,
    async () => geminiResponse({ ...generated("fr"), reply: "Autre chose?" }), undefined, false), /safe closing/);
});
