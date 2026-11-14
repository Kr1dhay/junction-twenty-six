import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { demoReferrals } from "@edgecare/shared-types/fixtures";
import { draftNotes, liveScribeInstruction, mintSessionTokens, speakText, translateSegment, type ConsultationConfig } from "../src/server/consultation";
import { VoiceError } from "../src/server/voice";
import { GET as listConsultations, POST as storeConsultation } from "../src/app/referrals/[id]/consultations/route";
import { POST as sessionRoute } from "../src/app/demo/consultations/session/route";
import { POST as translateRoute } from "../src/app/demo/consultations/translate/route";
import { POST as referralPOST } from "../src/app/referrals/route";

const config: ConsultationConfig = { enabled: true, geminiKey: "gemini-test-secret", geminiModel: "configured-gemini-model", elevenKey: "eleven-test-secret", voiceID: "selected-demo-voice", sttModel: "scribe_v2", ttsModel: "eleven_v3", zeroRetention: false, liveModel: "gemini-3.8-live", realtimeSTTModel: "scribe_v3_live" };
const fixture = JSON.parse(readFileSync("packages/shared-types/fixtures/consultation.json", "utf8"));
const gemini = (value: unknown) => Response.json({ candidates: [{ content: { parts: [{ text: JSON.stringify(value) }] } }] });
const sessionInput = { consent: true as const, referral_id: fixture.referral_id, doctor_language: "en", patient_language: "so" };

test("session minting returns short-lived tokens and locks Gemini Live to a fixed scribe configuration", async () => {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetcher: typeof fetch = async (url, init) => {
    calls.push({ url: String(url), init: init! });
    return String(url).includes("elevenlabs") ? Response.json({ token: "scribe-single-use" }) : Response.json({ name: "auth_tokens/ephemeral" });
  };
  const now = () => new Date("2026-11-14T10:00:00.000Z");
  const result = await mintSessionTokens(sessionInput, config, fetcher, undefined, now);
  assert.equal(calls[0]!.url, "https://api.elevenlabs.io/v1/single-use-token/realtime_scribe");
  assert.equal((calls[0]!.init.headers as Record<string, string>)["xi-api-key"], "eleven-test-secret");
  const body = JSON.parse(calls[1]!.init.body as string);
  assert.equal(calls[1]!.url, "https://generativelanguage.googleapis.com/v1beta/auth_tokens");
  assert.equal(body.uses, 1);
  assert.equal(body.expireTime, "2026-11-14T10:30:00.000Z");
  assert.equal(body.liveConnectConstraints.model, "models/gemini-3.8-live");
  assert.deepEqual(body.liveConnectConstraints.config.responseModalities, ["TEXT"]);
  assert.equal(body.liveConnectConstraints.config.systemInstruction.parts[0].text, liveScribeInstruction);
  assert.deepEqual(body.liveConnectConstraints.config.contextWindowCompression, { slidingWindow: {} });
  assert.equal(result.scribe.token, "scribe-single-use");
  assert.equal(result.scribe.model, "scribe_v3_live");
  assert.equal(result.live?.token, "auth_tokens/ephemeral");
  assert.ok(result.live?.url.endsWith("BidiGenerateContentConstrained"));
  assert.equal(JSON.stringify(result).includes("secret"), false);
});

test("recording is optional: a failed or unconfigured Gemini Live token still yields translation", async () => {
  const failing = await mintSessionTokens(sessionInput, config, async url => String(url).includes("elevenlabs") ? Response.json({ token: "t" }) : new Response("no", { status: 403 }));
  assert.equal(failing.live, null);
  const runware = await mintSessionTokens(sessionInput, { ...config, provider: "runware", runwareKey: "r", runwareModel: "google:gemini@3-flash", geminiKey: undefined }, async () => Response.json({ token: "t" }));
  assert.equal(runware.live, null);
  await assert.rejects(mintSessionTokens(sessionInput, { ...config, elevenKey: undefined }, async () => Response.json({})), (error: unknown) => error instanceof VoiceError && error.status === 503);
  await assert.rejects(mintSessionTokens(sessionInput, { ...config, enabled: false }, async () => Response.json({})), (error: unknown) => error instanceof VoiceError && error.status === 503);
});

test("translation is literal, schema-validated and spoken only in the target language", async () => {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetcher: typeof fetch = async (url, init) => {
    calls.push({ url: String(url), init: init! });
    return calls.length === 1 ? gemini({ translated_text: "About two months." }) : new Response(Buffer.from("mp3"), { headers: { "Content-Type": "audio/mpeg" } });
  };
  const result = await translateSegment({ consent: true, text: "Qiyaastii laba bilood.", source_language: "som", target_language: "en", speaker: "patient", synthesize: true }, { ...config, voices: { en: "english-voice" } }, fetcher);
  const request = JSON.parse(calls[0]!.init.body as string);
  assert.equal(request.generationConfig.temperature, 0);
  assert.equal(JSON.parse(request.contents[0].parts[0].text).source_language, "so");
  assert.ok(calls[1]!.url.includes("english-voice"));
  assert.equal(result.translated_text, "About two months.");
  assert.equal(result.speech_available, true);
  // TTS failure keeps the text translation.
  let n = 0;
  const textOnly = await translateSegment({ consent: true, text: "Hello", source_language: "en", target_language: "so", speaker: "doctor", synthesize: true }, config, async () => ++n === 1 ? gemini({ translated_text: "Salaan" }) : new Response("x", { status: 500 }));
  assert.equal(textOnly.translated_text, "Salaan"); assert.equal(textOnly.speech_available, false); assert.ok(textOnly.speech_error);
  await assert.rejects(translateSegment({ consent: true, text: "Hello", source_language: "en", target_language: "so", speaker: "doctor", synthesize: false }, config, async () => gemini({ translated_text: "" })), VoiceError);
  await assert.rejects(translateSegment({ consent: true, text: "Hello", source_language: "en", target_language: "en", speaker: "doctor", synthesize: false }, config, async () => gemini({})), (error: unknown) => error instanceof VoiceError && error.status === 400);
});

test("notes combine both transcripts, prefer corrections, and reject malformed drafts", async () => {
  let sent: { interpreted_transcript: { translation: string }[]; independent_recording_transcript: string } | undefined;
  const draft = { structured: fixture.structured, clinical_summary: fixture.clinical_summary, patient_language_summary: fixture.patient_language_summary, meeting_notes: fixture.meeting_notes, meeting_notes_patient_language: fixture.meeting_notes_patient_language, discrepancies: [] };
  const transcript = [{ ...fixture.transcript[1], correction: "About two months, maybe three." }];
  const result = await draftNotes({ consent: true, doctor_language: "en", patient_language: "so", transcript, live_transcript: "about two months", live_key_points: ["- Two months"] }, config, async (_url, init) => {
    sent = JSON.parse(JSON.parse(init!.body as string).contents[0].parts[0].text);
    return gemini(draft);
  });
  assert.equal(sent!.interpreted_transcript[0]!.translation, "About two months, maybe three.");
  assert.equal(sent!.independent_recording_transcript, "about two months");
  assert.deepEqual(result.structured, fixture.structured);
  await assert.rejects(draftNotes({ consent: true, doctor_language: "en", patient_language: "so", transcript, live_transcript: null, live_key_points: [] }, config, async () => gemini({ ...draft, diagnosis: "x" })), VoiceError);
});

const request = (path: string, method = "GET", body?: unknown, headers?: HeadersInit) => new Request(`http://localhost${path}`, { method, ...(body === undefined ? {} : { body: JSON.stringify(body) }), headers });
const context = (id: string) => ({ params: Promise.resolve({ id }) });

test("consultation routes require clinician access, both confirmations, a known referral and stay append-only", async () => {
  process.env.DEMO_MODE = "true"; process.env.CHAIN = "mock"; process.env.LLM = "ondevice";
  process.env.EDGECARE_DB_PATH = ":memory:";
  delete process.env.EDGECARE_CLOUD_VOICE;
  const referral = { ...demoReferrals[0]!, referral_id: "66666666-6666-4666-8666-666666666666" };
  assert.equal((await referralPOST(request("/referrals", "POST", referral))).status, 201);
  const id = referral.referral_id;
  const record = { ...fixture, referral_id: id };
  const path = `/referrals/${id}/consultations`;
  const browser = { "sec-fetch-site": "same-origin" };
  assert.equal((await storeConsultation(request(path, "POST", record, browser), context(id))).status, 401);
  assert.equal((await listConsultations(request(path, "GET", undefined, browser), context(id))).status, 401);
  const { patient_confirmed_at: _omitted, ...unconfirmed } = record.confirmation;
  assert.equal((await storeConsultation(request(path, "POST", { ...record, confirmation: unconfirmed }), context(id))).status, 400);
  assert.equal((await storeConsultation(request(path, "POST", { ...record, referral_id: fixture.referral_id }), context(id))).status, 400);
  const missing = "77777777-7777-4777-8777-777777777777";
  assert.equal((await storeConsultation(request(`/referrals/${missing}/consultations`, "POST", { ...record, referral_id: missing }), context(missing))).status, 404);
  assert.equal((await listConsultations(request(`/referrals/${missing}/consultations`), context(missing))).status, 404);
  assert.equal((await storeConsultation(request(path, "POST", record), context(id))).status, 201);
  assert.equal((await storeConsultation(request(path, "POST", record), context(id))).status, 200);
  assert.equal((await storeConsultation(request(path, "POST", { ...record, meeting_notes: "changed" }), context(id))).status, 409);
  const listed = await (await listConsultations(request(path), context(id))).json();
  assert.equal(listed.consultations.length, 1);
  assert.deepEqual(listed.consultations[0].structured, fixture.structured);
  // Provider routes: consent required, disabled cloud returns 503 without contacting providers.
  assert.equal((await sessionRoute(request("/demo/consultations/session", "POST", { ...sessionInput, consent: false }))).status, 400);
  // Same-language visits are valid (speaker is set by the clinician's toggle); here cloud is disabled.
  assert.equal((await sessionRoute(request("/demo/consultations/session", "POST", { ...sessionInput, patient_language: "en" }))).status, 503);
  assert.equal((await sessionRoute(request("/demo/consultations/session", "POST", sessionInput))).status, 503);
  assert.equal((await translateRoute(request("/demo/consultations/translate", "POST", { consent: true, text: "hi", source_language: "en", target_language: "so", speaker: "doctor" }))).status, 503);
  assert.equal((await translateRoute(request("/demo/consultations/translate", "POST", { consent: true, text: "hi", source_language: "en", target_language: "so", speaker: "doctor" }, browser))).status, 401);
});

test("read-aloud speaks the exact confirmed text in the requested language", async () => {
  let body: { text: string; language_code: string } | undefined;
  const result = await speakText({ consent: true, text: "Tijaabo: koobitaan.", language: "som" }, config, async (_url, init) => {
    body = JSON.parse(init!.body as string);
    return new Response(Buffer.from("mp3"), { headers: { "Content-Type": "audio/mpeg" } });
  });
  assert.equal(body!.text, "Tijaabo: koobitaan.");
  assert.equal(body!.language_code, "so");
  assert.equal(result.speech_available, true);
});
