import { z } from "zod";
import { accessGuard } from "../../../../server/auth";
import { explainBrief } from "../../../../server/equity-explanation";
import { demoGuard, json, readJSON } from "../../../../server/http";
import { logConfigFailure } from "../../../../server/env-check";
import { loadPathwayData } from "../../../../server/pathway-data";
import { buildPathway, snapshot } from "../../../../lib/pathway";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 45;
export async function POST(request: Request) {
  const guard = demoGuard() ?? accessGuard(request, "clinician");
  if (guard) return guard;
  let input;
  try {
    input = z.object({ region: z.number().int().positive(), basis: z.enum(["live", "snapshot"]) }).strict().parse(await readJSON(request, 2048));
  } catch { return json({ error: "Choose a valid county." }, 400); }
  // Explain the same figures the page is showing: the snapshot, or the live refresh when the page has it.
  const data = input.basis === "snapshot" ? snapshot : await loadPathwayData();
  const pathway = buildPathway(data, input.region);
  if (!pathway) return json({ error: "Choose a valid county." }, 400);
  if (input.basis === "live" && !data.live) return json({ error: "AI explanation unavailable. The data-based brief remains available." }, 503);
  if (!pathway.furthest) return json({ error: "No stage is flagged for this county." }, 400);
  try { return json(await explainBrief(pathway)); }
  catch (error) {
    logConfigFailure("CRM equity AI explanation", error instanceof Error ? error.message : "provider error");
    return json({ error: "AI explanation unavailable. The data-based brief remains available." }, 503); }
}
