import type { z } from "zod";
import { accessGuard } from "./auth";
import { demoGuard, json, readJSON } from "./http";
import { logConfigFailure } from "./env-check";
import { VoiceError } from "./voice";

/** Shared handler: clinician-only, bounded body, schema-validated, provider errors mapped to status codes. */
export async function consultationRoute<S extends z.ZodType>(request: Request, schema: S, maximumBytes: number, run: (input: z.infer<S>, signal: AbortSignal) => Promise<unknown>) {
  const guard = demoGuard() ?? accessGuard(request, "clinician"); if (guard) return guard;
  let body: unknown;
  try { body = await readJSON(request, maximumBytes); } catch { return json({ error: "Expected a bounded JSON request" }, 400); }
  const parsed = schema.safeParse(body);
  if (!parsed.success) return json({ error: "Explicit consent and a valid consultation request are required" }, 400);
  try { return json(await run(parsed.data, request.signal)); }
  catch (error) {
    const feature = `Consultation ${new URL(request.url).pathname}`;
    if (error instanceof VoiceError) { logConfigFailure(feature, error.message); return json({ error: error.message }, error.status); }
    logConfigFailure(feature, error instanceof Error ? error.message : "provider error");
    return json({ error: "The cloud provider response was unavailable. Continue the consultation without translation." }, 502);
  }
}
