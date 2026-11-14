import { voiceAccessGuard } from "../../../../../server/auth";
import { demoGuard, json, readJSON } from "../../../../../server/http";
import { createLiveSession, liveSessionRequestSchema } from "../../../../../server/gemini-live";
import { VoiceError } from "../../../../../server/voice";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 30;
export async function POST(request: Request) {
  const guard = demoGuard() ?? voiceAccessGuard(request); if (guard) return guard;
  let body: unknown;
  try { body = await readJSON(request, 256 * 1024); } catch { return json({ error: "Expected a bounded Live session request" }, 400); }
  const parsed = liveSessionRequestSchema.safeParse(body);
  if (!parsed.success) return json({ error: "Explicit consent and a valid intake context are required" }, 400);
  try { return json(await createLiveSession(parsed.data, undefined, undefined, request.signal)); }
  catch (error) { return json({ error: error instanceof VoiceError ? error.message : "Gemini Live is unavailable" }, error instanceof VoiceError ? error.status : 502); }
}
