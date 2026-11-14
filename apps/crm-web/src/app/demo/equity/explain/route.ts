import { z } from "zod";
import { accessGuard } from "../../../../server/auth";
import { explainAction } from "../../../../server/equity-explanation";
import { demoGuard, json, readJSON } from "../../../../server/http";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 45;
export async function POST(request: Request) {
  const guard = demoGuard() ?? accessGuard(request, "clinician");
  if (guard) return guard;
  let input;
  try {
    input = z.object({ id: z.enum(["screening", "acknowledgment", "attendance"]), scenario: z.literal("baseline") }).strict().parse(await readJSON(request, 2048));
  } catch { return json({ error: "Choose a valid scenario action." }, 400); }
  try { return json(await explainAction(input.id, input.scenario)); }
  catch { return json({ error: "AI explanation unavailable. The reviewed evidence and action plan remain available." }, 503); }
}
