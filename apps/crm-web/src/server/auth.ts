import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { json } from "./http";

const state = globalThis as typeof globalThis & { edgecareSessionSecret?: string };
const secret = () => state.edgecareSessionSecret ??= randomBytes(32).toString("hex");
const signature = (payload: string) => createHmac("sha256", secret()).update(payload).digest("hex");
const equal = (a: string, b: string) => {
  const first = Buffer.from(a); const second = Buffer.from(b);
  return first.length === second.length && timingSafeEqual(first, second);
};
function externalURL(request: Request): URL | undefined {
  const internal = new URL(request.url);
  const host = request.headers.get("host");
  if (!host) return internal;
  if (!/^(?:[A-Za-z0-9.-]+|\[[A-Fa-f0-9:]+\])(?::[0-9]{1,5})?$/.test(host)) return;
  try { return new URL(`${internal.protocol}//${host}`); } catch { return; }
}
export const isLoopback = (request: Request) => {
  const url = externalURL(request);
  return Boolean(url && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname));
};
export function sessionAccessGuard(request: Request): Response | undefined {
  if (!sameOrigin(request)) return json({ error: "Cross-origin requests are not allowed" }, 403);
  const token = process.env.EDGECARE_CLINICIAN_TOKEN;
  const bearer = request.headers.get("authorization");
  if (token ? !bearer || !equal(bearer, `Bearer ${token}`) : !isLoopback(request)) return json({ error: "An authorized clinician demo token is required" }, 401);
}
export function createSession() {
  const payload = `${Date.now() + 8 * 60 * 60 * 1000}.${randomBytes(16).toString("hex")}`;
  return `${payload}.${signature(payload)}`;
}
export function validSession(value: string | undefined) {
  if (!value) return false;
  const parts = value.split(".");
  if (parts.length !== 3 || !/^\d+$/.test(parts[0]!)) return false;
  return Number(parts[0]) > Date.now() && equal(parts[2]!, signature(`${parts[0]}.${parts[1]}`));
}
export function sessionFrom(request: Request) {
  return request.headers.get("cookie")?.split(";").map(part => part.trim()).find(part => part.startsWith("edgecare_demo_session="))?.split("=")[1];
}
export function sameOrigin(request: Request) {
  const origin = request.headers.get("origin");
  const external = externalURL(request);
  return Boolean(external && (!origin || origin === external.origin));
}
export function accessGuard(request: Request, role: "clinician" | "issuer"): Response | undefined {
  if (!sameOrigin(request)) return json({ error: "Cross-origin requests are not allowed" }, 403);
  if (role === "clinician" && validSession(sessionFrom(request))) return;
  const configured = role === "clinician" ? process.env.EDGECARE_CLINICIAN_TOKEN : process.env.EDGECARE_ISSUER_TOKEN;
  const bearer = request.headers.get("authorization");
  if (configured && bearer && equal(bearer, `Bearer ${configured}`)) return;
  // Explicit synthetic-only local adapter. Browsers must enter the demo workspace.
  const loopback = isLoopback(request);
  const native = !request.headers.has("sec-fetch-site") && !request.headers.has("origin");
  if (!configured && loopback && native) return;
  return json({ error: "A clinician demo session or authorized device token is required" }, 401);
}

export function voiceAccessGuard(request: Request) {
  if (!sameOrigin(request)) return json({ error: "Cross-origin requests are not allowed" }, 403);
  if (validSession(sessionFrom(request))) return;
  return accessGuard(request, "issuer");
}
