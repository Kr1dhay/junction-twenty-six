import { consultationSpeakRequestSchema } from "@edgecare/shared-types";
import { consultationRoute } from "../../../../server/consultation-route";
import { speakText } from "../../../../server/consultation";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function POST(request: Request) {
  return consultationRoute(request, consultationSpeakRequestSchema, 32 * 1024, (input, signal) => speakText(input, undefined, undefined, signal));
}
