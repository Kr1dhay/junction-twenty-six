import { requireDemoMode } from "./config";
export function json(body: unknown, status = 200) {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
}
export function demoGuard(): Response | undefined {
  try { requireDemoMode(); } catch { return json({ error: "Local demo is not configured" }, 503); }
}
