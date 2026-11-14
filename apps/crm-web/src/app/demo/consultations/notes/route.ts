import { consultationNotesRequestSchema } from "@edgecare/shared-types";
import { consultationRoute } from "../../../../server/consultation-route";
import { draftNotes } from "../../../../server/consultation";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 120;
export async function POST(request: Request) {
  return consultationRoute(request, consultationNotesRequestSchema, 4 * 1024 * 1024, (input, signal) => draftNotes(input, undefined, undefined, signal));
}
