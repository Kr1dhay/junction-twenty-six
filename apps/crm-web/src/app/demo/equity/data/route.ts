import { accessGuard } from "../../../../server/auth";
import { demoGuard, json } from "../../../../server/http";
import { loadPathwayData } from "../../../../server/pathway-data";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 30;
/** Public county statistics for the equity page. No referral or patient data is read or returned. */
export async function GET(request: Request) {
  const guard = demoGuard() ?? accessGuard(request, "clinician");
  if (guard) return guard;
  return json(await loadPathwayData());
}
