import { z } from "zod";
import { backend } from "../../../../server/backend";
import { accessGuard } from "../../../../server/auth";
import { appointmentReadGuard, appointmentError } from "../../../../server/appointment-route";
import { canonicalID, demoGuard, json, readJSON } from "../../../../server/http";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
type Context = { params: Promise<{ id: string }> };
const bookingSchema = z.object({ slot_id: z.string().min(1).max(80), operation_id: z.string().refine(canonicalID) }).strict();
const cancelSchema = z.object({ appointment_id: z.string().refine(canonicalID) }).strict();

export async function GET(request: Request, context: Context) {
  const guard = demoGuard() ?? appointmentReadGuard(request); if (guard) return guard;
  const { id } = await context.params;
  if (!canonicalID(id)) return json({ error: "Invalid referral ID" }, 400);
  if (!await backend().get(id)) return json({ error: "Referral not found" }, 404);
  return json({ appointment: await backend().appointmentFor(id) ?? null, demo: true });
}
export async function POST(request: Request, context: Context) {
  const guard = demoGuard() ?? accessGuard(request, "issuer"); if (guard) return guard;
  const { id } = await context.params;
  if (!canonicalID(id)) return json({ error: "Invalid referral ID" }, 400);
  let body: unknown;
  try { body = await readJSON(request, 1024); } catch { return json({ error: "Expected a bounded booking request" }, 400); }
  const parsed = bookingSchema.safeParse(body);
  if (!parsed.success) return json({ error: "Invalid booking request" }, 400);
  try { return json({ appointment: await backend().bookAppointment(id, parsed.data.slot_id, parsed.data.operation_id), demo: true }); }
  catch (error) { return appointmentError(error); }
}
export async function DELETE(request: Request, context: Context) {
  const guard = demoGuard() ?? accessGuard(request, "issuer"); if (guard) return guard;
  const { id } = await context.params;
  if (!canonicalID(id)) return json({ error: "Invalid referral ID" }, 400);
  let body: unknown;
  try { body = await readJSON(request, 1024); } catch { return json({ error: "Expected a bounded cancellation request" }, 400); }
  const parsed = cancelSchema.safeParse(body);
  if (!parsed.success) return json({ error: "Invalid cancellation request" }, 400);
  try { return json({ appointment: await backend().cancelAppointment(id, parsed.data.appointment_id), demo: true }); }
  catch (error) { return appointmentError(error); }
}
