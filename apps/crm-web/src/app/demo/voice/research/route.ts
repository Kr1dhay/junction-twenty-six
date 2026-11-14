import { accessGuard } from "../../../../server/auth";
import { demoGuard, json, readJSON } from "../../../../server/http";
import { assessResearchVoice, voiceResearchAvailable, VoiceResearchError } from "../../../../server/voice-research";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 45;
function guard(request: Request) {
  return demoGuard() ?? (accessGuard(request, "issuer") ? accessGuard(request, "clinician") : undefined);
}
export async function GET(request: Request) {
  const denied = guard(request); if (denied) return denied;
  return json({ available: await voiceResearchAvailable() });
}
export async function POST(request: Request) {
  const denied = guard(request); if (denied) return denied;
  let input: unknown;
  try { input = await readJSON(request, 720 * 1024); }
  catch { return json({ error: "Provide a short, consented sustained-vowel recording." }, 400); }
  try { return json(await assessResearchVoice(input)); }
  catch (error) {
    const status = error instanceof VoiceResearchError ? error.status : 503;
    // Never log recordings, raw model output, or credentials.
    return json({ error: status === 400 ? "A consented, unprocessed 2–12 second WAV recording is required." :
      "Research voice analysis is unavailable. Continue with clinician review." }, status);
  }
}
