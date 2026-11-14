import { consultationSessionRequestSchema } from "@edgecare/shared-types";
import { consultationRoute } from "../../../../server/consultation-route";
import { mintSessionTokens } from "../../../../server/consultation";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function POST(request: Request) {
  return consultationRoute(request, consultationSessionRequestSchema, 16 * 1024, (input, signal) => mintSessionTokens(input, undefined, undefined, signal));
}
