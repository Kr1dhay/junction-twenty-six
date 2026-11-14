import { voiceAccessGuard } from "../../../../server/auth";
import { demoGuard, json } from "../../../../server/http";
import { voiceEngine } from "../../../../server/gemini-live";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function GET(request: Request) {
  const guard = demoGuard() ?? voiceAccessGuard(request); if (guard) return guard;
  try { return json({ engine: voiceEngine() }); }
  catch { return json({ error: "Voice configuration is unavailable" }, 503); }
}
