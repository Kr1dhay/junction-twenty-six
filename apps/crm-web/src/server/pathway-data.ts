import { z } from "zod";
import { pathwayIndicatorIDs, snapshot, type Cell, type PathwayData } from "../lib/pathway";

const API = "https://sotkanet.fi/rest/1.1/json";
const freshFor = 6 * 60 * 60_000, retryAfter = 5 * 60_000;
const rowsSchema = z.array(z.object({
  region: z.number().int(), year: z.number().int(), gender: z.string(),
  value: z.number().finite().nullable().optional(), absValue: z.number().finite().nullable().optional(),
}));
let cache: { at: number; data: PathwayData } | undefined;
export function resetPathwayCache() { cache = undefined; }

/**
 * County figures for the equity page: refreshed from THL Sotkanet at most every six hours, and the
 * committed snapshot whenever the live source is slow, down, incomplete or switched off.
 * Only public aggregate statistics are requested; nothing about referrals is sent.
 */
export async function loadPathwayData(fetcher: typeof fetch = fetch, now = Date.now()): Promise<PathwayData> {
  if (process.env.EDGECARE_PUBLIC_DATA === "snapshot") return { ...snapshot, live: false };
  if (cache && now - cache.at < (cache.data.live ? freshFor : retryAfter)) return cache.data;
  let data: PathwayData;
  try { data = await refresh(fetcher, now); }
  catch { data = { ...snapshot, live: false }; }
  cache = { at: now, data };
  return data;
}

async function refresh(fetcher: typeof fetch, now: number): Promise<PathwayData> {
  const national = snapshot.national_region_id;
  const counties = new Set(snapshot.regions.map(region => region.id));
  const thisYear = new Date(now).getUTCFullYear();
  const entries = await Promise.all(pathwayIndicatorIDs.map(async id => {
    const known = snapshot.indicators[id];
    if (!known) throw new Error("Indicator missing from snapshot");
    const years = Array.from({ length: Math.max(1, thisYear - known.year + 1) }, (_, index) => `years=${known.year + index}`).join("&");
    const response = await fetcher(`${API}?indicator=${id}&${years}&genders=total`, { signal: AbortSignal.timeout(8000), cache: "no-store" });
    if (!response.ok) throw new Error(`Sotkanet returned HTTP ${response.status}`);
    const rows = rowsSchema.parse(await response.json()).filter(row => row.gender === "total" && typeof row.value === "number");
    const cell = (region: number, year: number): Cell | null => {
      const row = rows.find(item => item.region === region && item.year === year);
      return row ? { value: row.value!, ...(typeof row.absValue === "number" ? { count: row.absValue } : {}) } : null;
    };
    const year = Math.max(...rows.filter(row => row.region === national).map(row => row.year));
    const whole = Number.isFinite(year) ? cell(national, year) : null;
    const values = Object.fromEntries([...counties].flatMap(region => { const value = cell(region, year); return value ? [[region, value]] : []; }));
    // A newly opened year with only a few counties published would distort every rank.
    if (!whole || Object.keys(values).length < Object.values(known.values).filter(Boolean).length - 2) throw new Error("Incomplete live data");
    return [id, { ...known, year, national: whole, values }] as const;
  }));
  return { ...snapshot, generated_at: new Date(now).toISOString(), live: true, indicators: Object.fromEntries(entries) };
}
