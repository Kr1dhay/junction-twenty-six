import { voiceTurnRoute } from "../../../../server/voice-route";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 180;
export async function POST(request: Request) { return voiceTurnRoute(request); }
