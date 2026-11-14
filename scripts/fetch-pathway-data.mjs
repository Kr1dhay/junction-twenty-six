// Regenerates the committed public-data snapshot used by the CRM equity page.
// Source: THL Sotkanet open API. Run with `pnpm pathway:snapshot`.
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const API = "https://sotkanet.fi/rest/1.1";
// Keep in step with `pathwayIndicatorIDs` in apps/crm-web/src/lib/pathway.ts.
const INDICATORS = [6103, 3621, 3620, 6411, 5201, 5208, 13, 3625, 3627];
const POPULATION = 127;
const thisYear = new Date().getUTCFullYear();
const years = Array.from({ length: 8 }, (_, index) => `years=${thisYear - index}`).join("&");

async function get(path) {
  const response = await fetch(`${API}${path}`, { signal: AbortSignal.timeout(90_000) });
  if (!response.ok) throw new Error(`Sotkanet returned HTTP ${response.status} for ${path}`);
  return response.json();
}
const shortName = name => name.replace(/ wellbeing services county$/, "").replace(/^City of /, "");

const allRegions = await get("/regions");
const country = allRegions.find(region => region.category === "MAA");
const counties = allRegions.filter(region => region.category === "HYVINVOINTIALUE");
if (!country || counties.length < 20) throw new Error("Unexpected Sotkanet region list");
const wanted = new Set([country.id, ...counties.map(region => region.id)]);

async function latest(id) {
  const rows = (await get(`/json?indicator=${id}&${years}&genders=total`))
    .filter(row => wanted.has(row.region) && row.gender === "total" && typeof row.value === "number");
  // Use the newest year in which the national figure and most counties are published.
  const year = Math.max(...rows.filter(row => row.region === country.id).map(row => row.year));
  const current = rows.filter(row => row.year === year);
  const cell = row => row ? { value: row.value, ...(typeof row.absValue === "number" ? { count: row.absValue } : {}) } : null;
  return { year, national: cell(current.find(row => row.region === country.id)),
    values: Object.fromEntries(current.filter(row => row.region !== country.id).map(row => [row.region, cell(row)])) };
}

const population = await latest(POPULATION);
const indicators = {};
for (const id of INDICATORS) {
  const meta = await get(`/indicators/${id}`);
  const data = await latest(id);
  if (!data.national || Object.keys(data.values).length < 15) throw new Error(`Indicator ${id} has too little county data`);
  indicators[id] = { id, title: meta.title.en, organization: meta.organization.title.en, updated: meta["data-updated"], ...data };
  console.log(`${id} ${meta.title.en.slice(0, 70)} · ${data.year} · ${Object.keys(data.values).length} counties`);
}

const snapshot = {
  generated_at: new Date().toISOString(),
  source: "THL Sotkanet open API",
  source_url: "https://sotkanet.fi/",
  national_region_id: country.id,
  regions: counties.map(region => ({ id: region.id, code: region.code, name: shortName(region.title.en), full_name: region.title.en,
    population: population.values[region.id]?.value ?? null })).sort((a, b) => a.name.localeCompare(b.name, "en")),
  population_year: population.year,
  indicators,
};
const target = fileURLToPath(new URL("../apps/crm-web/src/lib/pathway-snapshot.json", import.meta.url));
writeFileSync(target, `${JSON.stringify(snapshot, null, 1)}\n`);
console.log(`Wrote ${snapshot.regions.length} counties to ${target}`);
