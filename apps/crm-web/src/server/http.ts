import { requireDemoMode } from "./config";
export function json(body: unknown, status = 200) {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
}
export function demoGuard(): Response | undefined {
  try { requireDemoMode(); } catch { return json({ error: "Synthetic demo backend is not configured" }, 503); }
}
export const canonicalID = (id: string) => /^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(id);
export async function readJSON(request: Pick<Request, "body">, maximumBytes = 128 * 1024): Promise<unknown> {
  // Bound the streamed body as well as Content-Length; never buffer arbitrary uploads.
  const reader = request.body?.getReader();
  if (!reader) throw new Error("Expected JSON");
  const chunks: Uint8Array[] = []; let length = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > maximumBytes) { await reader.cancel(); throw new Error("Request too large"); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  return JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown;
}
