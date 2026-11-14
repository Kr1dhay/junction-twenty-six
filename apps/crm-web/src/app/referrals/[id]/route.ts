import { backend } from "../../../server/backend";
import { accessGuard } from "../../../server/auth";
import { canonicalID, demoGuard, json } from "../../../server/http";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  const guard = demoGuard() ?? accessGuard(request, "clinician"); if (guard) return guard;
  const { id } = await context.params;
  if (!canonicalID(id)) return json({ error: "Invalid referral ID" }, 400);
  const record = await backend().get(id);
  return record ? json(record) : json({ error: "Referral not found" }, 404);
}
