import type { CRMReferral } from "@edgecare/shared-types";

/** Workspace review point for an open referral. A local demo threshold, not a clinical standard. */
export const reviewAfterDays = 7;
const day = 86_400_000, hour = 3_600_000, minute = 60_000;
type Timed = Pick<CRMReferral, "created_at" | "status" | "status_history">;

/** Time from receipt until now (open) or until verification (used). Expired referrals have no wait. */
export function waitMs(record: Timed, now: number): number | null {
  const created = Date.parse(record.created_at);
  if (!Number.isFinite(created)) return null;
  if (record.status === "open") return Math.max(0, now - created);
  if (record.status !== "spent") return null;
  const seen = Date.parse(record.status_history.find(event => event.status === "spent")?.at ?? "");
  return Number.isFinite(seen) ? Math.max(0, seen - created) : null;
}
export function overdue(record: Timed, now: number): boolean {
  return record.status === "open" && (waitMs(record, now) ?? 0) > reviewAfterDays * day;
}
export function formatWait(ms: number): string {
  if (ms < hour) return `${Math.max(1, Math.floor(ms / minute))} min`;
  if (ms < day) return `${Math.floor(ms / hour)} h`;
  const hours = Math.floor((ms % day) / hour);
  return `${Math.floor(ms / day)} d${hours ? ` ${hours} h` : ""}`;
}
function median(values: number[]): number | null {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b), middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle]! : (sorted[middle - 1]! + sorted[middle]!) / 2;
}
export function waitingSummary(records: Timed[], now: number) {
  const open = records.filter(record => record.status === "open").map(record => waitMs(record, now)).filter(value => value !== null);
  const verified = records.filter(record => record.status === "spent").map(record => waitMs(record, now)).filter(value => value !== null);
  return { open: open.length, longestOpen: open.length ? Math.max(...open) : null, medianOpen: median(open),
    overdue: records.filter(record => overdue(record, now)).length, verified: verified.length, medianToVerified: median(verified) };
}
/** Open referrals first, longest waiting at the top; everything else newest first. */
export function byLongestWaiting(a: Timed, b: Timed): number {
  if ((a.status === "open") !== (b.status === "open")) return a.status === "open" ? -1 : 1;
  return a.status === "open" ? a.created_at.localeCompare(b.created_at) : b.created_at.localeCompare(a.created_at);
}
