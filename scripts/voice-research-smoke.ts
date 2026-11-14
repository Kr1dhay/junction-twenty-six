/** End-to-end LOCAL smoke test with synthetic sound, never a clinical test. */
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { demoReferrals } from "../packages/shared-types/src/fixtures";
import { voiceResearchAssessmentSchema } from "../packages/shared-types/src/index";

async function main() {
  const connection = JSON.parse(readFileSync("artifacts/voice-demo/connection.json", "utf8"));
  const origin = new URL(connection.backend_url);
  assert.equal(origin.protocol, "http:");
  assert.equal(origin.hostname, "127.0.0.1", "Smoke test is limited to the isolated local demo");
  const issuer = { authorization: `Bearer ${connection.issuer_token}`, "content-type": "application/json" };
  const clinician = { authorization: `Bearer ${connection.clinician_token}` };
  const endpoint = new URL("/demo/voice/research", origin);
  assert.equal((await fetch(endpoint)).status, 401);
  assert.deepEqual(await (await fetch(endpoint, { headers: issuer })).json(), { available: true });
  function sample(quiet = false) {
    const count = 6 * 16000;
    const audio = Buffer.alloc(44 + count * 2);
    audio.write("RIFF"); audio.writeUInt32LE(audio.length - 8, 4); audio.write("WAVEfmt ", 8);
    audio.writeUInt32LE(16, 16); audio.writeUInt16LE(1, 20); audio.writeUInt16LE(1, 22);
    audio.writeUInt32LE(16000, 24); audio.writeUInt32LE(32000, 28);
    audio.writeUInt16LE(2, 32); audio.writeUInt16LE(16, 34); audio.write("data", 36);
    audio.writeUInt32LE(count * 2, 40);
    if (!quiet) for (let i = 0; i < count; i++) {
      audio.writeInt16LE(Math.round(4500 * Math.sin(2 * Math.PI * 180 * i / 16000)), 44 + i * 2);
    }
    return { consent: true, task: "sustained_a", capture_mode: "measurement", audio_base64: audio.toString("base64") };
  }
  const refused = await fetch(endpoint, { method: "POST", headers: issuer, body: JSON.stringify({ ...sample(), consent: false }) });
  assert.equal(refused.status, 400);
  const quiet = await fetch(endpoint, { method: "POST", headers: issuer, body: JSON.stringify(sample(true)) });
  assert.equal(quiet.status, 200);
  assert.equal((await quiet.json()).outcome, "inconclusive");
  const response = await fetch(endpoint, { method: "POST", headers: issuer, body: JSON.stringify(sample()) });
  assert.equal(response.status, 200);
  const result = voiceResearchAssessmentSchema.parse(await response.json());
  assert.equal(result.model_id, "paterson-mfcc-lr-hackathon-demo");
  assert.ok(["flagged", "not_flagged"].includes(result.outcome), "Adequate sample must reach the real model");
  const record = { ...demoReferrals[0]!, referral_id: randomUUID(), created_at: new Date().toISOString(),
    expires_at: new Date(Date.now() + 30 * 86400000).toISOString(), status: "open",
    free_text_summary: "Hackathon pipeline test: synthetic sound, not patient data.",
    patient_language_summary: "Synthetic demo only. No clinical conclusion can be drawn.",
    voice_research: result };
  const stored = await fetch(new URL("/referrals", origin), { method: "POST", headers: issuer, body: JSON.stringify(record) });
  assert.equal(stored.status, 201);
  const retrieved = await (await fetch(new URL(`/referrals/${record.referral_id}`, origin), { headers: clinician })).json();
  assert.deepEqual(retrieved.voice_research, result);
  assert.equal(retrieved.risk_score, record.risk_score);
  const crm = await (await fetch(new URL("/referrals", origin), { headers: clinician })).json();
  const projected = crm.referrals.find((entry: { referral_id: string }) => entry.referral_id === record.referral_id);
  assert.deepEqual(projected.voice_research, result);
  assert.equal(JSON.stringify(projected).includes("audio_base64"), false);
  console.log(JSON.stringify({ passed: true, model_id: result.model_id, model_version: result.model_version,
    synthetic_audio_outcome: result.outcome, referral_id: record.referral_id,
    verified: ["device authentication", "consent", "quiet abstention", "real model inference", "referral persistence", "CRM projection"],
    clinical_validation: false }, null, 2));
}

main().catch(() => {
  // Do not print request objects, connection credentials or raw audio on errors.
  console.error("Local voice demo smoke test failed. Check artifacts/voice-demo service logs.");
  process.exitCode = 1;
});
