import { backend } from "../../../server/backend";
import { appointmentReadGuard } from "../../../server/appointment-route";
import { demoGuard, json } from "../../../server/http";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function GET(request: Request) {
  const guard = demoGuard() ?? appointmentReadGuard(request); if (guard) return guard;
  return json({ slots: await backend().appointmentSlots(), demo: true });
}
