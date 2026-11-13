import { backend } from "../../../server/backend";
import { demoGuard, json } from "../../../server/http";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function GET(_request: Request, context: { params: Promise<{ id: string }> }) {
  const guard = demoGuard(); if (guard) return guard;
  const { id } = await context.params;
  const record = backend().get(id);
  return record ? json(record) : json({ error: "Referral not found" }, 404);
}
