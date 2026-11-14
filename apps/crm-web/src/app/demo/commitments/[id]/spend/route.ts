import { spendRequestSchema } from "@edgecare/shared-types";
import { backend } from "../../../../../server/backend";
import { accessGuard } from "../../../../../server/auth";
import { canonicalID, demoGuard, json, readJSON } from "../../../../../server/http";
import { ConflictError, MissingError } from "../../../../../server/repository";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  const guard = demoGuard() ?? accessGuard(request, "clinician"); if (guard) return guard;
  const { id } = await context.params;
  if (!canonicalID(id)) return json({ error: "Invalid referral ID" }, 400);
  let body: unknown;
  try { body = await readJSON(request); } catch { return json({ error: "Expected JSON commitment" }, 400); }
  const parsed = spendRequestSchema.safeParse(body);
  if (!parsed.success) return json({ error: "Only a lowercase SHA-256 commitment_hash is accepted" }, 400);
  try {
    const store = backend();
    store.spend(id, parsed.data.commitment_hash, parsed.data.operation_id);
    return json(store.read(id));
  } catch (error) {
    if (error instanceof MissingError) return json({ error: error.message }, 404);
    if (error instanceof ConflictError) return json({ error: error.message }, 409);
    throw error;
  }
}
