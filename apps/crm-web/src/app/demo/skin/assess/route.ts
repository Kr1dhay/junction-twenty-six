import { skinAssessmentRequestSchema } from "@edgecare/shared-types";
import { voiceAccessGuard } from "../../../../server/auth";
import { demoGuard, json, readJSON } from "../../../../server/http";
import { runSkinAssessment } from "../../../../server/skin-assessment";
import { VoiceError } from "../../../../server/voice";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

/** Kiosk skin photo -> CNN -> Gemini risk score. The photo is processed in memory only and never stored or logged. */
export async function POST(request: Request) {
  const guard = demoGuard() ?? voiceAccessGuard(request); if (guard) return guard;
  let body: unknown;
  try { body = await readJSON(request, 12 * 1024 * 1024); } catch { return json({ error: "Expected a JSON skin assessment under 12 MiB" }, 400); }
  const parsed = skinAssessmentRequestSchema.safeParse(body);
  if (!parsed.success) return json({ error: "Explicit consent and a valid photo are required" }, 400);
  try { return json(await runSkinAssessment(parsed.data, { signal: request.signal })); }
  catch (error) {
    if (error instanceof VoiceError) return json({ error: error.message }, error.status);
    console.warn(`skin assessment failed: ${error instanceof Error ? error.message : "error"}`);
    return json({ error: "The skin assessment is unavailable. Continue without it." }, 502);
  }
}
