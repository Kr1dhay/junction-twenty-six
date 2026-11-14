import { OwnershipError } from "../../../server/profile-deletion";
import { backend } from "../../../server/backend";
import { accessGuard } from "../../../server/auth";
import { canonicalID, demoGuard, json, readJSON } from "../../../server/http";
import { referralSchema } from "@edgecare/shared-types";
import { z } from "zod";
import { ConflictError, MissingError } from "../../../server/repository";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  const guard = demoGuard() ?? accessGuard(request, "clinician"); if (guard) return guard;
  const { id } = await context.params;
  if (!canonicalID(id)) return json({ error: "Invalid referral ID" }, 400);
  const record = await backend().get(id);
  return record ? json(record) : json({ error: "Referral not found" }, 404);
}
const updateSchema = z.object({ expected: referralSchema, record: referralSchema }).strict();
export async function PATCH(request: Request, context: { params: Promise<{ id: string }> }) {
  const guard = demoGuard() ?? accessGuard(request, "issuer"); if (guard) return guard;
  const { id } = await context.params;
  if (!canonicalID(id)) return json({ error: "Invalid referral ID" }, 400);
  let body: unknown;
  try { body = await readJSON(request, 256 * 1024); } catch { return json({ error: "Expected a bounded referral update" }, 400); }
  const parsed = updateSchema.safeParse(body);
  if (!parsed.success || parsed.data.expected.referral_id !== id || parsed.data.record.referral_id !== id) return json({ error: "Invalid referral update" }, 400);
  try {
    await backend().update(parsed.data.expected, parsed.data.record);
    return json({ referral_id: id });
  } catch (error) {
    if (error instanceof MissingError) return json({ error: error.message }, 404);
    if (error instanceof ConflictError) return json({ error: error.message }, 409);
    throw error;
  }
}

/** Explicit patient erasure: a device token alone cannot delete an existing profile. */
export async function DELETE(request: Request, context: { params: Promise<{ id: string }> }) {
  const guard = demoGuard() ?? accessGuard(request, "clinician"); if (guard) return guard;
  const { id } = await context.params;
  if (!canonicalID(id)) return json({ error: "Invalid referral ID" }, 400);
  let body: unknown;
  try { body = await readJSON(request, 1024); } catch { return json({ error: "Expected a bounded deletion request" }, 400); }
  const parsed = z.object({ encryption_key: z.string().regex(/^[A-Za-z0-9+/]{43}=$/) }).strict().safeParse(body);
  if (!parsed.success) return json({ error: "Invalid deletion proof" }, 400);
  try {
    await backend().deleteProfile(id, parsed.data.encryption_key);
    return json({ deleted: true });
  } catch (error) {
    if (error instanceof OwnershipError) return json({ error: error.message }, 403);
    throw error;
  }
}
