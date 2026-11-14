import { consultationTranslateRequestSchema } from "@edgecare/shared-types";
import { consultationRoute } from "../../../../server/consultation-route";
import { translateSegment } from "../../../../server/consultation";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function POST(request: Request) {
  return consultationRoute(request, consultationTranslateRequestSchema, 64 * 1024, (input, signal) => translateSegment(input, undefined, undefined, signal));
}
