/**
 * Reports which backend features are usable with the current environment, and which variable names
 * are missing for the rest. Only variable NAMES are ever reported, never values.
 * Mirrors the checks in config.ts, auth.ts, backend.ts, voice.ts, gemini-live.ts, consultation.ts
 * and equity-explanation.ts; keep them in sync when those change.
 */
export type Severity = "fatal" | "disabled" | "ok";
export interface FeatureStatus {
  feature: string;
  severity: Severity;
  /** Variable names that must be added or corrected for this feature. */
  missing: string[];
  /** What a user sees when the feature is unavailable. */
  effect: string;
}

type Env = Record<string, string | undefined>;
const runwareGeminiModels = new Set(["google:gemini@3.1-pro", "google:gemini@3-flash", "google:gemini@3.1-flash-lite"]);
const has = (env: Env, name: string) => Boolean(env[name]?.trim());

export function checkEnvironment(env: Env = process.env): FeatureStatus[] {
  const hosted = Boolean(env.VERCEL);
  const result: FeatureStatus[] = [];
  const add = (feature: string, missing: string[], effect: string, severity: Exclude<Severity, "ok"> = "disabled") =>
    result.push({ feature, missing, effect, severity: missing.length ? severity : "ok" });

  add("Demo safety switches", [
    ...(env.DEMO_MODE === "true" ? [] : ["DEMO_MODE=true"]),
    ...(env.CHAIN === "mock" ? [] : ["CHAIN=mock"]),
    ...(env.LLM === "ondevice" ? [] : ["LLM=ondevice"]),
  ], "Every referral API request fails: the server refuses to run without the demo adapters.", "fatal");

  if (hosted) {
    add("Hosted database", has(env, "DATABASE_URL") ? [] : ["DATABASE_URL"], "All referral storage fails on Vercel (no SQLite fallback).", "fatal");
    add("Browser CRM sessions", (env.EDGECARE_SESSION_SECRET?.length ?? 0) >= 32 ? [] : ["EDGECARE_SESSION_SECRET (32+ characters)"],
      "The browser CRM cannot sign in on Vercel.", "fatal");
    add("HTTPS origin check", /^https:\/\//.test(env.EDGECARE_PUBLIC_ORIGIN ?? "") ? [] : ["EDGECARE_PUBLIC_ORIGIN (https://…)"],
      "Origin is derived from the Host header instead of trusted configuration.");
  }
  add("Device access tokens", ["EDGECARE_CLINICIAN_TOKEN", "EDGECARE_ISSUER_TOKEN"].filter(name => !has(env, name)),
    hosted ? "Doctor/kiosk apps cannot authenticate; their API calls return 401."
      : "Only loopback (this Mac) native apps can call the API; LAN devices are rejected.",
    hosted ? "fatal" : "disabled");

  const cloud = env.EDGECARE_CLOUD_VOICE === "true";
  const cloudSwitch = cloud ? [] : ["EDGECARE_CLOUD_VOICE=true"];
  const provider = env.VOICE_LLM_PROVIDER ?? "gemini";
  const textLLM = provider === "runware"
    ? [...["RUNWARE_API_KEY", "RUNWARE_MODEL"].filter(name => !has(env, name)),
       ...(has(env, "RUNWARE_MODEL") && !runwareGeminiModels.has(env.RUNWARE_MODEL!) ? [`RUNWARE_MODEL (one of ${[...runwareGeminiModels].join(", ")})`] : [])]
    : provider === "gemini" ? ["GEMINI_API_KEY", "GEMINI_MODEL"].filter(name => !has(env, name))
    : ["VOICE_LLM_PROVIDER (gemini or runware)"];
  const eleven = has(env, "ELEVENLABS_API_KEY") ? [] : ["ELEVENLABS_API_KEY"];

  add("Kiosk voice conversation (legacy turn-based)", [...cloudSwitch, ...eleven, ...textLLM],
    "Kiosk voice intake is unavailable; patients use the structured form.");
  add("Spoken replies (text-to-speech)", [...cloudSwitch, ...eleven, ...(has(env, "ELEVENLABS_VOICE_ID") ? [] : ["ELEVENLABS_VOICE_ID"])],
    "Replies and translations are shown as text only, without audio.");
  const liveModel = env.GEMINI_LIVE_MODEL ?? "gemini-3.8-live";
  add("Kiosk Gemini Live streaming voice", [...cloudSwitch, ...(has(env, "GEMINI_API_KEY") ? [] : ["GEMINI_API_KEY"]),
    ...(liveModel === "gemini-3.8-live" ? [] : ["GEMINI_LIVE_MODEL=gemini-3.8-live"])],
    "Kiosk falls back to the legacy voice engine (or the form).");
  add("Doctor live translation and transcription", [...cloudSwitch, ...eleven, ...textLLM],
    "Starting a consultation fails; the visit continues without translation.");
  add("Doctor consultation recorder (Gemini Live key points)", [...cloudSwitch, ...eleven, ...textLLM, ...(has(env, "GEMINI_API_KEY") ? [] : ["GEMINI_API_KEY"])],
    "Consultations run without the Gemini Live recorder (translation transcript only).");
  add("CRM equity actions AI explanation", [
    ...["RUNWARE_API_KEY", "RUNWARE_MODEL"].filter(name => !has(env, name)),
    ...(has(env, "RUNWARE_MODEL") && !runwareGeminiModels.has(env.RUNWARE_MODEL!) ? [`RUNWARE_MODEL (one of ${[...runwareGeminiModels].join(", ")})`] : []),
  ], "The equity page shows evidence and plans but no AI explanation.");

  return result.map(status => ({ ...status, missing: [...new Set(status.missing)] }));
}

/** Logs one line per feature at startup. Fatal problems go to console.error. */
export function logEnvironment(statuses = checkEnvironment(), log: Pick<Console, "info" | "warn" | "error"> = console) {
  const problems = statuses.filter(status => status.severity !== "ok");
  const where = process.env.VERCEL ? "Vercel" : "local";
  if (!problems.length) { log.info(`[edgecare env] ${where}: all ${statuses.length} features configured.`); return; }
  log.warn(`[edgecare env] ${where}: ${statuses.length - problems.length}/${statuses.length} features configured. Missing configuration:`);
  for (const status of problems) {
    const line = `[edgecare env]   ${status.severity === "fatal" ? "FATAL" : "disabled"}: ${status.feature} — set ${status.missing.join(", ")}. ${status.effect}`;
    if (status.severity === "fatal") log.error(line); else log.warn(line);
  }
}

/** Per-request log when a feature fails for configuration reasons (names only, never values). */
export function logConfigFailure(feature: string, reason: string) {
  console.warn(`[edgecare env] ${feature} unavailable: ${reason.slice(0, 300)}`);
}
