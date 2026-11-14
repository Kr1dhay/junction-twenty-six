import { commitmentRequestSchema } from "@edgecare/shared-types";
import { backend } from "../../../../server/backend";
import { accessGuard } from "../../../../server/auth";
import { canonicalID, demoGuard, json, readJSON } from "../../../../server/http";
import { ConflictError } from "../../../../server/repository";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
type Context = { params: Promise<{ id: string }> };
export async function GET(request: Request, context: Context) {
  const guard = demoGuard() ?? accessGuard(request, "clinician"); if (guard) return guard;
  const { id } = await context.params;
  if (!canonicalID(id)) return json({ error: "Invalid referral ID" }, 400);
  const account = backend().read(id);
  return account ? json(account) : json({ error: "Commitment not found" }, 404);
}
export async function PUT(request: Request, context: Context) {
  const guard = demoGuard() ?? accessGuard(request, "issuer"); if (guard) return guard;
  const { id } = await context.params;
  if (!canonicalID(id)) return json({ error: "Invalid referral ID" }, 400);
  let body: unknown;
  try { body = await readJSON(request); } catch { return json({ error: "Expected JSON commitment" }, 400); }
  const parsed = commitmentRequestSchema.safeParse(body);
  if (!parsed.success) return json({ error: "Only a lowercase SHA-256 commitment_hash is accepted" }, 400);
  try {
    const store = backend();
    store.create(id, parsed.data.commitment_hash);
    return json(store.read(id));
  } catch (error) {
    if (error instanceof ConflictError) return json({ error: error.message }, 409);
    throw error;
  }
}
