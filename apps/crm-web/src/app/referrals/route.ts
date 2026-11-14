import { referralSchema } from "@edgecare/shared-types";
import { backend } from "../../server/backend";
import { ConflictError, DeletedError } from "../../server/repository";
import { demoGuard, json, readJSON } from "../../server/http";
import { accessGuard } from "../../server/auth";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function GET(request: Request) {
  const guard = demoGuard() ?? accessGuard(request, "clinician"); if (guard) return guard;
  return json({ referrals: await backend().list() });
}
export async function POST(request: Request) {
  const guard = demoGuard() ?? accessGuard(request, "issuer"); if (guard) return guard;
  let body: unknown;
  try { body = await readJSON(request); } catch { return json({ error: "Expected a JSON enrollment under 128 KiB" }, 400); }
  const parsed = referralSchema.safeParse(body);
  if (!parsed.success || parsed.data.status !== "open") return json({ error: "Invalid enrollment record" }, 400);
  try {
    const result = await backend().create(parsed.data);
    return json({ referral_id: parsed.data.referral_id }, result.created ? 201 : 200);
  } catch (error) {
    if (error instanceof DeletedError) return json({ error: error.message }, 410);
    if (error instanceof ConflictError) return json({ error: error.message }, 409);
    throw error;
  }
}
