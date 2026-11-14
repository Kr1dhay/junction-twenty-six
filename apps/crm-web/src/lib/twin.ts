import snapshotJSON from "./twin-snapshot.json";

/**
 * Access digital twin for Helsinki primary care.
 *
 * Geography is public, area-level data (see twin-snapshot.json `sources`): a 250 m resident grid,
 * sub-district shares of residents with a foreign mother tongue and residents aged 75+, and the
 * city's health stations with their published opening hours. No patient, referral, nationality or
 * immigration-status data is used. Clinician numbers, interpreting coverage and the share of people
 * who need evening appointments are not published, so they are planning assumptions the user sets.
 *
 * Accessibility uses the enhanced two-step floating catchment area method (E2SFCA, Luo & Qi 2009)
 * with a Gaussian travel-time decay. Travel times are estimates from straight-line distance, not a
 * journey planner.
 */

export type Area = { id: number; name: string; population: number; foreign_language: number; aged_75: number };
export type Station = { id: number; name: string; full_name: string; lon: number; lat: number; hours: { day: number; extended: number };
  wheelchair_shortcomings: number | null; url: string | null };
export type Library = { id: number; name: string; lon: number; lat: number };
export type Source = { id: string; title: string; publisher: string; licence: string; url: string };
export type TwinData = { generated_at: string; region: string; sources: Source[]; cell_size_m: number; areas: Area[];
  cells: [number, number, number, number][]; stations: Station[]; libraries: Library[] };
export const twinData = snapshotJSON as TwinData;

export type GroupID = "everyone" | "language" | "step_free" | "extended";
export const groups: { id: GroupID; label: string; detail: string }[] = [
  { id: "everyone", label: "Everyone", detail: "All residents in the 250 m population grid." },
  { id: "language", label: "May need an interpreter", detail: "Residents whose mother tongue is not Finnish, Sami or Swedish, by sub-district. A proxy: many of them need no interpreter." },
  { id: "step_free", label: "Needs a step-free route", detail: "Residents aged 75 or over, by sub-district. A proxy for reduced mobility." },
  { id: "extended", label: "Needs evening or Saturday hours", detail: "A planning share of residents who cannot attend on weekdays between 8 and 16." },
];

export type Assumptions = {
  /** Clinicians per health station in an ordinary week. Not published; set locally. */
  clinicians: number;
  /** Clinician hours of appointments per week. */
  hoursPerClinician: number;
  /** Share of language-support needs a station meets with phone or video interpreting alone. */
  remoteInterpreting: number;
  /** Share of residents who need appointments outside weekdays 8–16. */
  extendedNeed: number;
  /** Weekly hours of a mobile clinic with one clinician; half of them outside weekdays 8–16. */
  vehicleHours: number;
  /** Share of a station's clinicians absent in a typical week (sick leave, vacancies). */
  absence: number;
};
export const defaultAssumptions: Assumptions = { clinicians: 8, hoursPerClinician: 30, remoteInterpreting: 0.5, extendedNeed: 0.25, vehicleHours: 30, absence: 0.12 };

export type Disruptions = { transitStrike: boolean; remoteInterpretingDown: boolean; closed: number[] };
export const noDisruptions: Disruptions = { transitStrike: false, remoteInterpretingDown: false, closed: [] };

export type Resource = "clinician" | "interpreter" | "vehicle";
export const resources: { id: Resource; label: string; unit: string }[] = [
  { id: "clinician", label: "One extra clinician", unit: "at a health station" },
  { id: "interpreter", label: "One on-site interpreter", unit: "at a health station" },
  { id: "vehicle", label: "One mobile clinic", unit: "parked at a public library" },
];

// Travel model: estimates from straight-line distance with a street detour factor.
export const travel = { walkKmh: 4.8, stepFreeKmh: 3.2, detour: 1.3, stepFreeDetour: 1.45, transitKmh: 19, transitWaitMin: 9, stepFreeTransitExtraMin: 6, catchmentMin: 40 };
const R = 6371;
function km(aLon: number, aLat: number, bLon: number, bLat: number) {
  const dLat = (bLat - aLat) * Math.PI / 180, dLon = (bLon - aLon) * Math.PI / 180;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(aLat * Math.PI / 180) * Math.cos(bLat * Math.PI / 180) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}
/** Door-to-door minutes, choosing the faster of walking and public transport. */
export function minutes(distanceKm: number, stepFree: boolean, transit: boolean) {
  const walk = distanceKm * (stepFree ? travel.stepFreeDetour : travel.detour) / (stepFree ? travel.stepFreeKmh : travel.walkKmh) * 60;
  if (!transit) return walk;
  const ride = travel.transitWaitMin + (stepFree ? travel.stepFreeTransitExtraMin : 0) + distanceKm * travel.detour / travel.transitKmh * 60;
  return Math.min(walk, ride);
}
/** Gaussian decay from 1 at the door to 0 at the catchment edge. */
export function decay(min: number, catchment = travel.catchmentMin) {
  if (min >= catchment) return 0;
  const edge = Math.exp(-0.5);
  return (Math.exp(-0.5 * (min / catchment) ** 2) - edge) / (1 - edge);
}

export type Site = { kind: "station" | "library"; id: number; name: string; lon: number; lat: number;
  /** Share of capacity outside weekdays 8–16. */ extendedShare: number;
  /** Multiplier for the step-free group from published accessibility shortcomings. */ stepFreeFactor: number };
export function stationSite(station: Station): Site {
  const total = station.hours.day + station.hours.extended;
  const shortcomings = station.wheelchair_shortcomings;
  return { kind: "station", id: station.id, name: station.name, lon: station.lon, lat: station.lat, extendedShare: total ? station.hours.extended / total : 0,
    stepFreeFactor: shortcomings === null ? 0.75 : shortcomings === 0 ? 1 : Math.max(0.4, 1 - 0.15 * shortcomings) };
}
// A mobile clinic works half its hours outside 8–16 and has a lift (planning assumptions).
export const librarySite = (library: Library): Site => ({ kind: "library", id: library.id, name: library.name, lon: library.lon, lat: library.lat, extendedShare: 0.5, stepFreeFactor: 1 });

/** Travel weights cell × site, for the two route types. Cached per travel multiplier and transit state. */
export type Weights = { normal: Float32Array; stepFree: Float32Array; sites: number };
export function buildWeights(data: TwinData, sites: Site[], transit: boolean, slowdown = 1): Weights {
  const n = data.cells.length, m = sites.length;
  const normal = new Float32Array(n * m), stepFree = new Float32Array(n * m);
  for (let i = 0; i < n; i++) {
    const [lon, lat] = data.cells[i]!;
    for (let j = 0; j < m; j++) {
      const site = sites[j]!, d = km(lon, lat, site.lon, site.lat);
      normal[i * m + j] = decay(minutes(d, false, transit) * slowdown);
      stepFree[i * m + j] = decay(minutes(d, true, transit) * slowdown);
    }
  }
  return { normal, stepFree, sites: m };
}

/** Residents per cell and group, with optional per-sub-district demand multipliers. */
export function demand(data: TwinData, a: Assumptions, areaFactor?: Float64Array) {
  const n = data.cells.length;
  const everyone = new Float64Array(n), language = new Float64Array(n), stepFree = new Float64Array(n), extended = new Float64Array(n);
  data.cells.forEach(([, , residents, areaIndex], i) => {
    const area = data.areas[areaIndex]!, people = residents * (areaFactor?.[areaIndex] ?? 1);
    everyone[i] = people; language[i] = people * area.foreign_language; stepFree[i] = people * area.aged_75; extended[i] = people * a.extendedNeed;
  });
  return { everyone, language, step_free: stepFree, extended } satisfies Record<GroupID, Float64Array>;
}
export type Demand = ReturnType<typeof demand>;

/** Per-site supply state for one scenario. Capacity is in appointment-hours per week. */
export type Supply = { capacity: Float64Array; interpreting: Float64Array };
export function baselineSupply(data: TwinData, a: Assumptions, d: Disruptions, extraSites = 0): Supply {
  const m = data.stations.length + extraSites;
  const capacity = new Float64Array(m), interpreting = new Float64Array(m);
  data.stations.forEach((station, j) => {
    capacity[j] = d.closed.includes(station.id) ? 0 : a.clinicians * a.hoursPerClinician * (1 - a.absence);
    interpreting[j] = d.remoteInterpretingDown ? 0 : a.remoteInterpreting;
  });
  return { capacity, interpreting };
}

export type Access = Record<GroupID, Float64Array> & { target: number; ratio: Float64Array };
/**
 * E2SFCA. Capacity at each site is shared by every resident who can reach it (step 1); each group then
 * reaches only the part of it that suits them (interpreting, step-free entrance, opening hours) (step 2).
 */
export function access(data: TwinData, sites: Site[], w: Weights, people: Demand, supply: Supply, a: Assumptions): Access {
  const n = data.cells.length, m = w.sites;
  const ratio = new Float64Array(m);
  for (let j = 0; j < m; j++) {
    if (!supply.capacity[j]) continue;
    let reach = 0;
    for (let i = 0; i < n; i++) reach += people.everyone[i]! * w.normal[i * m + j]!;
    ratio[j] = reach ? supply.capacity[j]! / reach : 0;
  }
  const out = { everyone: new Float64Array(n), language: new Float64Array(n), step_free: new Float64Array(n), extended: new Float64Array(n) };
  for (let i = 0; i < n; i++) for (let j = 0; j < m; j++) {
    const r = ratio[j]!;
    if (!r) continue;
    const site = sites[j]!, wn = w.normal[i * m + j]!;
    out.everyone[i]! += r * wn;
    out.language[i]! += r * supply.interpreting[j]! * wn;
    out.step_free[i]! += r * site.stepFreeFactor * w.stepFree[i * m + j]!;
    out.extended[i]! += r * Math.min(1, site.extendedShare / a.extendedNeed) * wn;
  }
  let capacity = 0, residents = 0;
  for (const value of supply.capacity) capacity += value;
  for (const value of people.everyone) residents += value;
  return { ...out, target: residents ? capacity / residents : 0, ratio };
}

/** Resident-equivalents below the city average, per group: Σ people × shortfall share. */
export function shortfall(people: Demand, acc: Access, target = acc.target) {
  const result = {} as Record<GroupID, number>;
  for (const group of groups) {
    let total = 0;
    const p = people[group.id], v = acc[group.id];
    for (let i = 0; i < p.length; i++) if (v[i]! < target) total += p[i]! * (target - v[i]!) / target;
    result[group.id] = total;
  }
  return result;
}
export const total = (value: Record<GroupID, number>) => groups.reduce((sum, group) => sum + value[group.id], 0);

/** Gain in access from one intervention, without recomputing the whole city. */
export function candidateGain(people: Demand, acc: Access, sites: Site[], w: Weights, supply: Supply, a: Assumptions, resource: Resource, j: number, extra?: { ratio: number }) {
  const m = w.sites, n = people.everyone.length, target = acc.target;
  const site = sites[j]!;
  let dEveryone = 0, dLanguage = 0, dStepFree = 0, dExtended = 0;
  if (resource === "clinician" || resource === "vehicle") {
    // Adding capacity S to site j raises its ratio by S / (residents who can reach it).
    const added = resource === "clinician" ? a.hoursPerClinician * (1 - a.absence) : a.vehicleHours;
    let reach = 0;
    for (let i = 0; i < n; i++) reach += people.everyone[i]! * w.normal[i * m + j]!;
    const r = extra?.ratio ?? (reach ? added / reach : 0);
    dEveryone = r; dLanguage = r * supply.interpreting[j]!; dStepFree = r * site.stepFreeFactor; dExtended = r * Math.min(1, site.extendedShare / a.extendedNeed);
  } else {
    dLanguage = acc.ratio[j]! * (1 - supply.interpreting[j]!);
  }
  let gain = 0;
  const below = (value: number, delta: number) => value < target ? Math.min(delta, target - value) / target : 0;
  for (let i = 0; i < n; i++) {
    const wn = w.normal[i * m + j]!;
    if (!wn && !w.stepFree[i * m + j]) continue;
    if (dEveryone) gain += people.everyone[i]! * below(acc.everyone[i]!, dEveryone * wn);
    if (dLanguage) gain += people.language[i]! * below(acc.language[i]!, dLanguage * wn);
    if (dStepFree) gain += people.step_free[i]! * below(acc.step_free[i]!, dStepFree * w.stepFree[i * m + j]!);
    if (dExtended) gain += people.extended[i]! * below(acc.extended[i]!, dExtended * wn);
  }
  return gain;
}

/** Deterministic pseudo-random numbers, so a run can be repeated and tested. */
export function rng(seed: number) {
  let s = seed >>> 0;
  return () => { s = (s + 0x6d2b79f5) >>> 0; let t = s; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}
function normal(random: () => number) { return Math.sqrt(-2 * Math.log(1 - random())) * Math.cos(2 * Math.PI * random()); }

export type Candidate = { resource: Resource; site: Site; gains: number[] };
export type Suggestion = { resource: Resource; site: Site; meanGain: number; share: number; low: number; high: number; bestShare: number };
export type RunResult = { draws: number; scenarios: number; baselineShortfall: number; byResource: Record<Resource, Suggestion[]> };
export type RunOptions = { draws: number; seed: number; data?: TwinData; assumptions: Assumptions; disruptions: Disruptions;
  onProgress?: (done: number, totalScenarios: number) => void; yieldEvery?: number };

const slowdowns = [0.9, 1, 1.1, 1.25];
const quantile = (sorted: number[], q: number) => sorted[Math.min(sorted.length - 1, Math.max(0, Math.round(q * (sorted.length - 1))))]!;

/**
 * Monte Carlo over uncertain weeks. Each draw varies clinician absence, sub-district demand (±8%),
 * travel speed and the chance of one unplanned station closure, then scores every candidate under the
 * same draw (common random numbers). Scenarios = draws × (1 baseline + every candidate).
 */
export async function runScenarios(options: RunOptions): Promise<RunResult> {
  const data = options.data ?? twinData, a = options.assumptions, d = options.disruptions;
  const random = rng(options.seed);
  const stations = data.stations.map(stationSite), libraries = data.libraries.map(librarySite);
  const sites = [...stations, ...libraries];
  const open = stations.map((site, j) => ({ site, j })).filter(({ site }) => !d.closed.includes(site.id));
  const candidates: Candidate[] = [
    ...open.map(({ site }) => ({ resource: "clinician" as const, site, gains: [] })),
    ...open.map(({ site }) => ({ resource: "interpreter" as const, site, gains: [] })),
    ...libraries.map(site => ({ resource: "vehicle" as const, site, gains: [] })),
  ];
  const scenarios = options.draws * (candidates.length + 1);
  const weightCache = new Map<number, Weights>();
  const weights = (slowdown: number) => {
    let cached = weightCache.get(slowdown);
    if (!cached) { cached = buildWeights(data, sites, !d.transitStrike, slowdown); weightCache.set(slowdown, cached); }
    return cached;
  };
  const baselines: number[] = [];
  for (let draw = 0; draw < options.draws; draw++) {
    const slowdown = slowdowns[Math.floor(random() * slowdowns.length)]!;
    const w = weights(slowdown);
    const areaFactor = Float64Array.from(data.areas, () => Math.max(0.7, 1 + 0.08 * normal(random)));
    const people = demand(data, a, areaFactor);
    const supply = baselineSupply(data, a, d, libraries.length);
    stations.forEach((site, j) => {
      if (!supply.capacity[j]) return;
      let present = 0;
      for (let k = 0; k < a.clinicians; k++) if (random() >= a.absence) present++;
      supply.capacity[j] = present * a.hoursPerClinician;
    });
    if (random() < 0.1) supply.capacity[Math.floor(random() * stations.length)] = 0; // unplanned closure this week
    libraries.forEach((_, k) => { supply.interpreting[stations.length + k] = d.remoteInterpretingDown ? 0 : a.remoteInterpreting; });
    const acc = access(data, sites, w, people, supply, a);
    baselines.push(total(shortfall(people, acc)));
    for (const candidate of candidates) {
      const j = sites.indexOf(candidate.site);
      if (candidate.resource !== "vehicle" && !supply.capacity[j]) { candidate.gains.push(0); continue; }
      candidate.gains.push(candidateGain(people, acc, sites, w, supply, a, candidate.resource, j));
    }
    if (options.yieldEvery && (draw + 1) % options.yieldEvery === 0) {
      options.onProgress?.((draw + 1) * (candidates.length + 1), scenarios);
      await new Promise(resolve => setTimeout(resolve, 0));
    }
  }
  options.onProgress?.(scenarios, scenarios);
  const baselineShortfall = baselines.reduce((sum, value) => sum + value, 0) / baselines.length;
  const byResource = { clinician: [], interpreter: [], vehicle: [] } as Record<Resource, Suggestion[]>;
  for (const resource of resources.map(item => item.id)) {
    const pool = candidates.filter(candidate => candidate.resource === resource);
    const wins = new Map<Candidate, number>();
    for (let draw = 0; draw < options.draws; draw++) {
      let best: Candidate | undefined;
      for (const candidate of pool) if (!best || candidate.gains[draw]! > best.gains[draw]!) best = candidate;
      if (best) wins.set(best, (wins.get(best) ?? 0) + 1);
    }
    byResource[resource] = pool.map(candidate => {
      const sorted = [...candidate.gains].sort((x, y) => x - y);
      const meanGain = candidate.gains.reduce((sum, value) => sum + value, 0) / candidate.gains.length;
      return { resource, site: candidate.site, meanGain, share: baselineShortfall ? meanGain / baselineShortfall : 0,
        low: quantile(sorted, 0.05), high: quantile(sorted, 0.95), bestShare: (wins.get(candidate) ?? 0) / options.draws };
    }).sort((x, y) => y.meanGain - x.meanGain);
  }
  return { draws: options.draws, scenarios, baselineShortfall, byResource };
}

/**
 * The expected week, without random variation: used to draw the map before and after a change.
 * Both are scored against the city average before the change, so added capacity counts as a gain.
 */
export function expectedWeek(a: Assumptions, d: Disruptions, change?: { resource: Resource; site: Site }, data: TwinData = twinData) {
  const stations = data.stations.map(stationSite), libraries = data.libraries.map(librarySite);
  const sites = [...stations, ...libraries];
  const w = buildWeights(data, sites, !d.transitStrike);
  const people = demand(data, a);
  const supply = baselineSupply(data, a, d, libraries.length);
  libraries.forEach((_, k) => { supply.interpreting[stations.length + k] = d.remoteInterpretingDown ? 0 : a.remoteInterpreting; });
  const before = access(data, sites, w, people, supply, a);
  let after: Access | undefined;
  if (change) {
    const j = sites.findIndex(site => site.kind === change.site.kind && site.id === change.site.id);
    const changed = { capacity: Float64Array.from(supply.capacity), interpreting: Float64Array.from(supply.interpreting) };
    if (change.resource === "clinician") changed.capacity[j]! += a.hoursPerClinician * (1 - a.absence);
    if (change.resource === "vehicle") changed.capacity[j] = a.vehicleHours;
    if (change.resource === "interpreter") changed.interpreting[j] = 1;
    after = access(data, sites, w, people, changed, a);
  }
  const target = before.target;
  return { sites, people, before, after, target, shortfallBefore: shortfall(people, before, target), shortfallAfter: after ? shortfall(people, after, target) : undefined };
}

/** Each group's resident-weighted average access, as a share of the city average for everyone. */
export function averageAccess(people: Demand, acc: Access, target: number) {
  const result = {} as Record<GroupID, number>;
  for (const group of groups) {
    let weighted = 0, count = 0;
    const p = people[group.id], v = acc[group.id];
    for (let i = 0; i < p.length; i++) { weighted += p[i]! * v[i]!; count += p[i]!; }
    result[group.id] = count && target ? weighted / count / target : 0;
  }
  return result;
}
