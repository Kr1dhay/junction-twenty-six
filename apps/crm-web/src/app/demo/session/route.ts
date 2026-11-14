import { createSession, sameOrigin, sessionAccessGuard } from "../../../server/auth";
import { demoGuard, json } from "../../../server/http";
export const runtime = "nodejs";
export async function POST(request: Request) {
  const guard = demoGuard(); if (guard) return guard;
  const access = sessionAccessGuard(request); if (access) return access;
  const response = json({ role: "demo_clinician", synthetic_only: true });
  response.headers.set("Set-Cookie", `edgecare_demo_session=${createSession()}; Path=/; HttpOnly; SameSite=Strict; Max-Age=28800${process.env.EDGECARE_PUBLIC_ORIGIN || new URL(request.url).protocol === "https:" ? "; Secure" : ""}`);
  return response;
}
export async function DELETE(request: Request) {
  if (!sameOrigin(request)) return json({ error: "Cross-origin requests are not allowed" }, 403);
  const response = json({ signed_out: true });
  response.headers.set("Set-Cookie", "edgecare_demo_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0");
  return response;
}
