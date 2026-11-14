/** Explicit synthetic hosted smoke test. Provider calls require --live-voice. */
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { demoReferrals } from "../packages/shared-types/src/fixtures";
import { clinicalProfileSchema, type VoiceTurnResponse } from "../packages/shared-types/src/index";
import { z } from "zod";

const voiceTurnResponseSchema = z.object({
  transcript: z.string(), detected_language: z.string(), reply: z.string(), profile: clinicalProfileSchema,
  audio_base64: z.string().nullable(), audio_mime_type: z.literal("audio/mpeg").nullable(),
  speech_available: z.boolean(), speech_error: z.string().nullable(),
});

const require = createRequire(import.meta.url);
const app = resolve("apps/crm-web");
const next = require.resolve("next", { paths: [app] });
const { loadEnvConfig } = require(require.resolve("@next/env", { paths: [next] }));
loadEnvConfig(app, false, { info() {}, error() {} });
const origin = process.env.EDGECARE_PUBLIC_ORIGIN!;
assert.equal(new URL(origin).protocol, "https:");
const issuer = process.env.EDGECARE_ISSUER_TOKEN!;
const clinician = process.env.EDGECARE_CLINICIAN_TOKEN!;
assert.ok(issuer && clinician, "Set device credentials privately before verification");
const call = (path: string, token?: string, body?: unknown, method = body === undefined ? "GET" : "POST", headers: Record<string, string> = {}) => fetch(origin + path, {
  method, redirect: "error", headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body === undefined ? {} : { "content-type": "application/json" }), ...headers },
  ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(160_000),
});

async function main() {
  assert.equal((await call("/health")).status, 200);
  assert.equal((await call("/referrals")).status, 401);
  assert.equal((await call("/demo/voice/turn", undefined, { consent: true, text: "Hello" })).status, 401);
  assert.equal((await call("/demo/voice/turn", issuer, { consent: false, text: "Hello" })).status, 400);
  const session = await call("/demo/session", clinician, {}, "POST", { origin });
  assert.equal(session.status, 200);
  const cookie = session.headers.get("set-cookie")!;
  assert.ok(cookie.includes("Secure") && cookie.includes("HttpOnly"));
  assert.equal((await call("/referrals", undefined, undefined, "GET", { cookie })).status, 200);
  assert.equal((await call("/demo/session", clinician, {}, "POST", { origin: "https://attacker.example" })).status, 403);

  const record = { ...demoReferrals[0]!, referral_id: randomUUID(), created_at: new Date().toISOString(), expires_at: new Date(Date.now() + 86_400_000).toISOString() };
  assert.equal((await call("/referrals", issuer, record)).status, 201);
  assert.equal((await call("/referrals", issuer, record)).status, 200);
  const commitmentPath = `/demo/commitments/${record.referral_id}`;
  const hash = { commitment_hash: record.commitment_hash };
  assert.equal((await call(commitmentPath, issuer, hash, "PUT")).status, 200);
  const operations = [randomUUID(), randomUUID()];
  const race = await Promise.all(operations.map(operation_id => call(commitmentPath + "/spend", clinician, { ...hash, operation_id })));
  assert.deepEqual(race.map(result => result.status).sort(), [200, 409]);
  const winner = operations[race.findIndex(result => result.status === 200)];
  assert.equal((await call(commitmentPath + "/spend", clinician, { ...hash, operation_id: winner })).status, 200);
  const detail = await (await call(`/referrals/${record.referral_id}`, clinician)).json();
  assert.equal(detail.status, "spent");
  for (const key of ["salt", "signature_template_encrypted", "triage_detail_encrypted", "commitment_hash"]) assert.equal(key in detail, false);
  console.log("Hosted auth, browser cookie, enrollment, shared persistence, concurrent spend, replay and privacy passed.");

  const report: { origin: string; referral_id: string; voice: unknown[] } = { origin, referral_id: record.referral_id, voice: [] };
  if (process.argv.includes("--live-voice")) {
    const texts: Record<string, string> = {
      en: "I have had a cough for two days.", fi: "Minulla on ollut yskää kaksi päivää.",
      so: "Waxaan qufacayay laba maalmood.", ar: "أعاني من السعال منذ يومين.", ru: "У меня кашель уже два дня.",
    };
    let english: VoiceTurnResponse | undefined;
    for (const [language, text] of Object.entries(texts)) {
      const started = Date.now();
      const response = await call("/demo/voice/turn", issuer, { consent: true, text });
      assert.equal(response.status, 200, response.ok ? undefined : `Voice ${language}: ${await response.text()}`);
      const turn = voiceTurnResponseSchema.parse(await response.json());
      assert.equal(turn.detected_language, language);
      assert.equal(turn.speech_available, true);
      assert.ok(turn.audio_base64);
      assert.match(JSON.stringify(turn.profile), /cough/i);
      assert.match(turn.profile.duration_english, /two|2/i);
      report.voice.push({ language, duration_ms: Date.now() - started, profile: turn.profile, reply: turn.reply, audio_bytes: Buffer.from(turn.audio_base64, "base64").length });
      if (language === "en") english = turn;
      console.log(`Hosted ${language} conversation, English profile and ElevenLabs reply passed.`);
    }
    const corrected = await call("/demo/voice/turn", issuer, { consent: true, text: "Correction: the cough started three days ago, not two.", profile: english!.profile, history: [{ role: "user", text: texts.en }, { role: "assistant", text: english!.reply }] });
    assert.equal(corrected.status, 200);
    const updated = voiceTurnResponseSchema.parse(await corrected.json());
    assert.match(updated.profile.duration_english, /three|3/i);
    const audio = await call("/demo/voice/turn", issuer, { consent: true, audio_base64: readFileSync("artifacts/voice-probes/en.mp3").toString("base64"), audio_mime_type: "audio/mpeg" });
    assert.equal(audio.status, 200);
    const spoken = voiceTurnResponseSchema.parse(await audio.json());
    assert.equal(spoken.detected_language, "en");
    assert.equal(spoken.speech_available, true);
    report.voice.push({ correction_profile: updated.profile, audio_detection: spoken.detected_language });
    console.log("Hosted profile correction and automatic audio language detection passed.");
  }
  mkdirSync("artifacts", { recursive: true });
  writeFileSync("artifacts/hosted-verification.json", JSON.stringify(report, null, 2) + "\n");
}
main().catch(error => { console.error(error instanceof Error ? error.message : "Hosted verification failed"); process.exitCode = 1; });
