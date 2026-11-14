import { voiceTurnRequestSchema } from "@edgecare/shared-types";
import { voiceAccessGuard } from "./auth";
import { demoGuard, json, readJSON } from "./http";
import { logConfigFailure } from "./env-check";
import { runVoiceTurn, VoiceError } from "./voice";
export async function voiceTurnRoute(request: Request, synthesize = true) {
  const guard = demoGuard() ?? voiceAccessGuard(request); if (guard) return guard;
  let body: unknown;
  try { body = await readJSON(request, 9 * 1024 * 1024); } catch { return json({ error: "Expected a JSON voice turn under 9 MiB" }, 400); }
  const parsed = voiceTurnRequestSchema.safeParse(body);
  if (!parsed.success || (!synthesize && parsed.data.audio_base64)) return json({ error: "Explicit consent and exactly one valid text or audio turn are required" }, 400);
  try { return json(await runVoiceTurn(parsed.data, undefined, undefined, request.signal, synthesize)); }
  catch (error) {
    if (error instanceof VoiceError) { logConfigFailure("Kiosk voice turn", error.message); return json({ error: error.message }, error.status); }
    logConfigFailure("Kiosk voice turn", error instanceof Error ? error.message : "provider error");
    return json({ error: "The cloud provider response was unavailable. Continue with the offline form." }, 502);
  }
}
