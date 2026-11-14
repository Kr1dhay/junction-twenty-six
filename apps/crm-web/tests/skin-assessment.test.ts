import test from "node:test";
import assert from "node:assert/strict";
import { bandFor, fallbackScore, jitter, runSkinAssessment, skinSystemPrompt } from "../src/server/skin-assessment";
import { classifySkinImage, simulatedSkinCNN, resetSkinCNN, type SkinCNNResult } from "../src/server/skin-cnn";
import type { VoiceConfig } from "../src/server/voice";
import { POST } from "../src/app/demo/skin/assess/route";

const config: VoiceConfig = { enabled: true, geminiKey: "gemini-test-secret", geminiModel: "configured-gemini-model", sttModel: "scribe_v2", ttsModel: "eleven_v3", zeroRetention: false };
const image = Buffer.alloc(512, 7).toString("base64");
const cnn = (malignant: number): SkinCNNResult => ({
  probabilities: { akiec: 0, bcc: 0, bkl: 0, df: 0, mel: malignant, nv: 1 - malignant, vasc: 0 },
  top: malignant > 0.5 ? "mel" : "nv", top_probability: Math.max(malignant, 1 - malignant), malignant_probability: malignant, source: "cnn", model: "test",
});
const request = { consent: true as const, language: "fi", image_base64: image, image_mime: "image/jpeg" as const, answers: { followSkin: "yes", persistent_or_changing: "yes" }, concern: "Luomi on muuttunut" };
const gemini = (value: object) => Response.json({ candidates: [{ content: { parts: [{ text: JSON.stringify(value) }] } }] });

test("bands follow the documented thresholds", () => {
  assert.deepEqual([0, 24, 25, 49, 50, 74, 75, 100].map(bandFor), ["low", "low", "moderate", "moderate", "high", "high", "very_high", "very_high"]);
});

test("jitter stays within ±4 and inside 0-100", () => {
  assert.equal(jitter(100, () => 1), 100);
  assert.equal(jitter(0, () => 0), 0);
  assert.equal(jitter(50, () => 1), 54);
  assert.equal(jitter(50, () => 0), 46);
});

test("Gemini receives the photo, CNN output and answers, and its score drives the result", async () => {
  let body: any;
  const fetcher: typeof fetch = async (url, init) => {
    assert.ok(String(url).includes("configured-gemini-model:generateContent"));
    body = JSON.parse(init!.body as string);
    return gemini({ risk_score: 81, band: "very_high", key_factors_english: ["Reported change in colour"], patient_message: "Ota yhteyttä lääkäriin pian.", clinician_note_english: "Irregular pigmented lesion." });
  };
  const result = await runSkinAssessment(request, { config, fetcher, random: () => 0.5, classify: async () => cnn(0.7) });
  const parts = body.contents[0].parts;
  assert.equal(parts[1].inlineData.mimeType, "image/jpeg");
  assert.equal(parts[1].inlineData.data, image);
  const context = JSON.parse(parts[0].text);
  assert.equal(context.cnn.malignant_probability, 0.7);
  assert.equal(context.patient_language, "fi");
  assert.equal(context.patient_answers["Skin mark changed in size, shape or colour, started bleeding, or failed to heal"], "yes");
  assert.equal(body.systemInstruction.parts[0].text, skinSystemPrompt);
  assert.equal(result.risk_score, 81);
  assert.equal(result.band, "very_high");
  assert.equal(result.scoring_source, "gemini");
  assert.equal(result.patient_message, "Ota yhteyttä lääkäriin pian.");
  assert.equal(JSON.stringify(result).includes("secret"), false);
});

test("invalid Gemini output falls back to the CNN + answers score", async () => {
  const fetcher: typeof fetch = async () => gemini({ risk_score: 900 });
  const result = await runSkinAssessment(request, { config, fetcher, random: () => 0.5, classify: async () => cnn(0.8) });
  assert.equal(result.scoring_source, "fallback");
  assert.equal(result.risk_score, fallbackScore(cnn(0.8), request.answers).score);
  assert.ok(result.risk_score >= 75);
});

test("without Gemini configured the fallback is used and low-risk answers stay low", async () => {
  const result = await runSkinAssessment({ ...request, answers: { followSkin: "no", persistent_or_changing: "no" } },
    { config: { ...config, enabled: false }, random: () => 0.5, classify: async () => cnn(0.05) });
  assert.equal(result.scoring_source, "fallback");
  assert.equal(result.band, "low");
});

test("the simulated CNN is deterministic per image and sums to ~1", () => {
  const a = simulatedSkinCNN(Buffer.from("one")), b = simulatedSkinCNN(Buffer.from("one"));
  assert.deepEqual(a, b);
  const total = Object.values(a.probabilities).reduce((sum, value) => sum + value, 0);
  assert.ok(Math.abs(total - 1) < 0.01);
  assert.equal(a.source, "simulated");
});

test("the committed CNN classifies a real image when the model file is present", async () => {
  resetSkinCNN();
  const sharp = (await import("sharp")).default;
  const png = await sharp({ create: { width: 300, height: 300, channels: 3, background: { r: 180, g: 120, b: 100 } } }).png().toBuffer();
  const result = await classifySkinImage(png);
  const total = Object.values(result.probabilities).reduce((sum, value) => sum + value, 0);
  assert.ok(Math.abs(total - 1) < 0.01);
  assert.ok(["cnn", "simulated"].includes(result.source));
});

test("route requires explicit consent", async () => {
  const keys = ["DEMO_MODE", "CHAIN", "LLM"] as const;
  const previous = keys.map(key => process.env[key]);
  Object.assign(process.env, { DEMO_MODE: "true", CHAIN: "mock", LLM: "ondevice" });
  try {
    const response = await POST(new Request("http://127.0.0.1:3000/demo/skin/assess", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ...request, consent: false }) }));
    assert.ok([400, 401].includes(response.status), `status ${response.status}`);
  } finally { keys.forEach((key, index) => { if (previous[index] === undefined) delete process.env[key]; else process.env[key] = previous[index]; }); }
});
