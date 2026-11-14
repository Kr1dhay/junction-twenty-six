import { demoGuard, json } from "../../server/http";
import { backend } from "../../server/backend";
import { PostgresRepository } from "../../server/postgres-repository";
export const dynamic = "force-dynamic";
export const runtime = "nodejs";
export async function GET() {
  const guard = demoGuard(); if (guard) return guard;
  try {
    const store = backend();
    if (store instanceof PostgresRepository) await store.ping();
    return json({ status: "ok", demo_mode: true, database: "ready" });
  } catch { return json({ status: "unavailable", demo_mode: true, database: "unavailable" }, 503); }
}
