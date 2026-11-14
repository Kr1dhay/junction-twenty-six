import assert from "node:assert/strict";
import test from "node:test";
import { checkEnvironment, logEnvironment } from "../src/server/env-check";

const base = { DEMO_MODE: "true", CHAIN: "mock", LLM: "ondevice" };
const full = {
  ...base, VERCEL: "1", DATABASE_URL: "postgres://x", EDGECARE_SESSION_SECRET: "s".repeat(40), EDGECARE_PUBLIC_ORIGIN: "https://edge.example",
  EDGECARE_CLINICIAN_TOKEN: "c", EDGECARE_ISSUER_TOKEN: "i", EDGECARE_CLOUD_VOICE: "true", ELEVENLABS_API_KEY: "e", ELEVENLABS_VOICE_ID: "v",
  GEMINI_API_KEY: "g", GEMINI_MODEL: "m", RUNWARE_API_KEY: "r", RUNWARE_MODEL: "google:gemini@3-flash",
};
const byFeature = (env: Record<string, string>) => Object.fromEntries(checkEnvironment(env).map(status => [status.feature, status]));

test("a fully configured hosted environment reports every feature ready", () => {
  assert.deepEqual(checkEnvironment(full).filter(status => status.severity !== "ok"), []);
});

test("missing Runware disables only the equity explanation when Gemini handles text", () => {
  const { RUNWARE_API_KEY: _, ...env } = full;
  const problems = checkEnvironment(env).filter(status => status.severity !== "ok");
  assert.deepEqual(problems.map(status => status.feature), ["CRM equity actions AI explanation"]);
  assert.deepEqual(problems[0]!.missing, ["RUNWARE_API_KEY"]);
});

test("hosted deployments flag database, session secret and device tokens as fatal", () => {
  const status = byFeature({ ...base, VERCEL: "1" });
  assert.equal(status["Hosted database"]!.severity, "fatal");
  assert.equal(status["Browser CRM sessions"]!.severity, "fatal");
  assert.equal(status["Device access tokens"]!.severity, "fatal");
});

test("local runs treat cloud features as disabled, not fatal, and name the switch", () => {
  const status = byFeature(base);
  assert.equal(status["Hosted database"], undefined, "local runs use SQLite");
  assert.equal(status["Device access tokens"]!.severity, "disabled");
  assert.ok(status["Doctor live translation and transcription"]!.missing.includes("EDGECARE_CLOUD_VOICE=true"));
  assert.ok(status["Doctor live translation and transcription"]!.missing.includes("ELEVENLABS_API_KEY"));
});

test("runware text provider requires a supported model", () => {
  const status = byFeature({ ...full, VOICE_LLM_PROVIDER: "runware", RUNWARE_MODEL: "openai:gpt" });
  assert.ok(status["Doctor live translation and transcription"]!.missing.some(name => name.startsWith("RUNWARE_MODEL (one of")));
});

test("logs list variable names but never values", () => {
  const lines: string[] = [];
  const sink = { info: (line: string) => lines.push(line), warn: (line: string) => lines.push(line), error: (line: string) => lines.push(line) };
  const { GEMINI_API_KEY: _, ...env } = { ...full, ELEVENLABS_API_KEY: "eleven-secret-value" };
  logEnvironment(checkEnvironment(env), sink);
  const output = lines.join("\n");
  assert.match(output, /GEMINI_API_KEY/);
  assert.doesNotMatch(output, /eleven-secret-value|postgres:\/\/x/);
});
