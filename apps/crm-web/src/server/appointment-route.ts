import { accessGuard } from "./auth";
import { ConflictError, MissingError } from "./repository";
import { json } from "./http";

export function appointmentReadGuard(request: Request) {
  const issuer = accessGuard(request, "issuer");
  return issuer ? accessGuard(request, "clinician") : undefined;
}
export function appointmentError(error: unknown): Response {
  if (error instanceof MissingError) return json({ error: error.message }, 404);
  if (error instanceof ConflictError) return json({ error: error.message }, 409);
  throw error;
}
