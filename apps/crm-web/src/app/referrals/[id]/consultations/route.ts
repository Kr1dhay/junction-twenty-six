import { consultationSchema } from "@edgecare/shared-types";
import { backend } from "../../../../server/backend";
import { accessGuard } from "../../../../server/auth";
import { canonicalID, demoGuard, json, readJSON } from "../../../../server/http";
import { ConflictError, MissingError } from "../../../../server/repository";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  const guard = demoGuard() ?? accessGuard(request, "clinician"); if (guard) return guard;
  const { id } = await context.params;
  if (!canonicalID(id)) return json({ error: "Invalid referral ID" }, 400);
  const repository = backend();
  if (!await repository.verificationEnvelope(id)) return json({ error: "Referral not found" }, 404);
  return json({ consultations: await repository.listConsultations(id) });
}
/**
 * Stores a consultation only after both the patient and clinician confirmed it (enforced by the schema).
 * The health record keeps the confirmed summary and key points only: any word-for-word transcript an
 * older app build still sends is dropped before storage.
 */
export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  const guard = demoGuard() ?? accessGuard(request, "clinician"); if (guard) return guard;
  const { id } = await context.params;
  if (!canonicalID(id)) return json({ error: "Invalid referral ID" }, 400);
  let body: unknown;
  try { body = await readJSON(request, 4 * 1024 * 1024); } catch { return json({ error: "Expected a JSON consultation under 4 MiB" }, 400); }
  const parsed = consultationSchema.safeParse(body);
  if (!parsed.success || parsed.data.referral_id !== id) return json({ error: "Invalid or unconfirmed consultation" }, 400);
  try {
    const result = await backend().createConsultation({ ...parsed.data, transcript: [] });
    return json({ consultation_id: parsed.data.consultation_id }, result.created ? 201 : 200);
  } catch (error) {
    if (error instanceof MissingError) return json({ error: error.message }, 404);
    if (error instanceof ConflictError) return json({ error: error.message }, 409);
    throw error;
  }
}
