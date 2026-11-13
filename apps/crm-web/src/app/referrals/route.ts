import { referralSchema } from "@edgecare/shared-types";
import { backend } from "../../server/backend";
import { ConflictError } from "../../server/repository";
import { demoGuard, json } from "../../server/http";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function GET() {
  const guard = demoGuard(); if (guard) return guard;
  return json({ referrals: backend().list() });
}
export async function POST(request: Request) {
  const guard = demoGuard(); if (guard) return guard;
  let body: unknown;
  try { body = await request.json(); } catch { return json({ error: "Expected JSON" }, 400); }
  const parsed = referralSchema.safeParse(body);
  if (!parsed.success || parsed.data.status !== "open") return json({ error: "Invalid enrollment record" }, 400);
  try {
    const result = backend().create(parsed.data);
    return json({ referral_id: parsed.data.referral_id }, result.created ? 201 : 200);
  } catch (error) {
    if (error instanceof ConflictError) return json({ error: error.message }, 409);
    throw error;
  }
}
