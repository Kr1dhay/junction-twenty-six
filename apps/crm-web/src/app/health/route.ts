import { demoGuard, json } from "../../server/http";
import { backend } from "../../server/backend";
export const dynamic = "force-dynamic";
export function GET() { const guard = demoGuard(); if (guard) return guard; backend(); return json({ status: "ok", demo_mode: true }); }
