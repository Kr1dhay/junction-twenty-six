/**
 * Access digital twin for mainland Finland's public primary care.
 *
 * Geography is public aggregate data (see twin-snapshot.json `sources`): residents and residents aged 65+
 * per 2 km square, each municipality's share of foreign-language speakers, GP visits per 1,000 residents and
 * waits over 7 days, health stations, and villages. No patient, referral, nationality, citizenship or
 * immigration-status data is used.
 *
 * Every figure answers a plain question in plain units:
 *   - How far is care?           minutes to the nearest open health station, by car or without a car
 *   - Is there enough care?      GP visits a year within reach, per 1,000 residents (E2SFCA, Luo & Qi 2009)
 *   - Who needs language help?   foreign-language speakers per square (municipal share × residents)
 * Travel times are estimates from straight-line distance with a road detour, not a route planner.
 */

export type Municipality = { code: string; name: string; county: number; foreign_language: number; gp_visits_per_1000: number; wait_over_7_days: number | null };
export type Station = { id: number; name: string; lon: number; lat: number; muni: number; hours: { day: number; extended: number } | null; source: "ptv" | "osm" };
export type Stop = { id: number; name: string; lon: number; lat: number };
export type Source = { id: string; title: string; publisher: string; licence: string; url: string };
export type TwinData = { generated_at: string; region: string; sources: Source[]; cell_km: number; counties: { name: string; name_fi: string }[];
  municipalities: Municipality[]; cells: [number, number, number, number, number][]; stations: Station[]; stops: Stop[] };

export type Resource = "gp" | "interpreter" | "clinic";
export const resources: Record<Resource, { label: string; short: string; place: string; unit: string; why: string }> = {
  gp: { label: "One more GP", short: "GP", place: "at a health station", unit: "need-weighted visits a year",
    why: "A GP adds appointments. They help most where many people share few appointments." },
  interpreter: { label: "One on-site interpreter", short: "Interpreter", place: "at a health station", unit: "foreign-language speakers have this as their nearest station",
    why: "An interpreter helps everyone whose nearest health station it is, if they can get there within 30 minutes." },
  clinic: { label: "One mobile clinic stop", short: "Mobile clinic", place: "in a village one day a week", unit: "people brought within 30 minutes of care",
    why: "A mobile clinic helps people who are far from any health station." },
};

export type Settings = {
  /** Snow and ice: every road and bus trip takes 30% longer. */ storm: boolean;
  /** No buses: people without a car can only walk. */ busStrike: boolean;
  /** Station ids closed in this scenario. */ closed: number[];
  /** GP visits one extra full-time GP provides in a year (planning assumption). */ gpVisits: number;
  /** Share of residents aged 65+ who travel without a car (planning assumption). */ noCar65: number;
};
export const defaultSettings: Settings = { storm: false, busStrike: false, closed: [], gpVisits: 3500, noCar65: 0.35 };

// ---- Travel ------------------------------------------------------------------------------------------
export const travel = { detour: 1.3, carKmh: { urban: 30, town: 50, rural: 70 }, carExtraMin: 4, walkKmh: 4.8,
  busKmh: 30, busWaitMin: { urban: 8, town: 25, rural: 60 }, busExtraMin: 6, catchmentMin: 30, stormFactor: 1.3, nearby: 10 };
export type Density = 0 | 1 | 2; // urban, town, rural
const densityKey = ["urban", "town", "rural"] as const;
/** Settlement type from residents per km²: urban ≥ 1,000, town ≥ 100, otherwise rural. */
export const density = (residents: number, cellKm: number): Density => { const perKm2 = residents / (cellKm * cellKm); return perKm2 >= 1000 ? 0 : perKm2 >= 100 ? 1 : 2; };
export function carMinutes(distanceKm: number, from: Density, slow = 1) {
  return travel.carExtraMin + distanceKm * travel.detour / travel.carKmh[densityKey[from]] * 60 * slow;
}
export function noCarMinutes(distanceKm: number, from: Density, slow = 1, busStrike = false) {
  const walk = distanceKm * travel.detour / travel.walkKmh * 60;
  if (busStrike) return walk;
  const bus = travel.busWaitMin[densityKey[from]] + travel.busExtraMin + distanceKm * travel.detour / travel.busKmh * 60 * slow;
  return Math.min(walk, bus);
}
/** Gaussian decay from 1 at the door to 0 at the catchment edge. */
export function decay(minutes: number, catchment = travel.catchmentMin) {
  if (minutes >= catchment) return 0;
  const edge = Math.exp(-0.5);
  return (Math.exp(-0.5 * (minutes / catchment) ** 2) - edge) / (1 - edge);
}
export function km(aLon: number, aLat: number, bLon: number, bLat: number) {
  const dLat = (bLat - aLat) * Math.PI / 180, dLon = (bLon - aLon) * Math.PI / 180;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(aLat * Math.PI / 180) * Math.cos(bLat * Math.PI / 180) * Math.sin(dLon / 2) ** 2;
  return 2 * 6371 * Math.asin(Math.sqrt(h));
}

/**
 * In towns several stations are about equally close. Each square's residents are split between the open
 * stations within 5 km of its nearest one, nearer stations taking more (e-folding distance 1.5 km).
 */
const SPLIT_KM = 1.5, SPLIT_CUTOFF_KM = 5;
function split(near: Int32Array, nearKm: Float32Array, K: number, i: number, open: (j: number) => boolean, out: Float32Array, offset: number) {
  let nearestKm = Infinity, sum = 0;
  for (let r = 0; r < K; r++) { const j = near[i * K + r]!; if (j >= 0 && open(j)) nearestKm = Math.min(nearestKm, nearKm[i * K + r]!); }
  for (let r = 0; r < K; r++) {
    const j = near[i * K + r]!, extra = nearKm[i * K + r]! - nearestKm;
    out[offset + r] = j >= 0 && open(j) && extra <= SPLIT_CUTOFF_KM ? Math.exp(-extra / SPLIT_KM) : 0;
    sum += out[offset + r]!;
  }
  if (sum) for (let r = 0; r < K; r++) out[offset + r]! /= sum;
}

// ---- Prepared geometry --------------------------------------------------------------------------------
/** Nearest stations per square, squares near each stop, and per-square demand; computed once. */
export type Prepared = {
  data: TwinData; n: number; m: number;
  pop: Float64Array; p65: Float64Array; language: Float64Array; rate: Float64Array; density: Uint8Array; muni: Uint16Array;
  /** K nearest stations per square: index and km, row-major n × K. */ near: Int32Array; nearKm: Float32Array; k: number;
  /** Squares within 45 km of each stop (CSR). */ stopStart: Int32Array; stopCell: Int32Array; stopKm: Float32Array; stopMuni: Uint16Array;
  /** Visits a year each station delivers today: the residents who use it × their municipality's published rate. */ capacity: Float64Array;
  /** National GP visits a year per 1,000 residents. */ national: number;
};

class SpatialIndex {
  private buckets = new Map<string, number[]>();
  constructor(points: { lon: number; lat: number }[], private size = 0.25) { points.forEach((point, i) => this.bucket(point.lon, point.lat).push(i)); }
  private bucket(lon: number, lat: number) {
    const key = `${Math.floor(lon / (this.size * 2))}:${Math.floor(lat / this.size)}`;
    let found = this.buckets.get(key);
    if (!found) this.buckets.set(key, found = []);
    return found;
  }
  /** Indices within `rings` buckets of the point (a bucket is about 28 km square). */
  around(lon: number, lat: number, rings: number) {
    const x = Math.floor(lon / (this.size * 2)), y = Math.floor(lat / this.size), out: number[] = [];
    for (let dx = -rings; dx <= rings; dx++) for (let dy = -rings; dy <= rings; dy++) out.push(...(this.buckets.get(`${x + dx}:${y + dy}`) ?? []));
    return out;
  }
}

export function prepare(data: TwinData, k = travel.nearby): Prepared {
  const n = data.cells.length, m = data.stations.length;
  const pop = new Float64Array(n), p65 = new Float64Array(n), language = new Float64Array(n), rate = new Float64Array(n);
  const dens = new Uint8Array(n), muni = new Uint16Array(n);
  data.cells.forEach(([, , residents, aged, municipality], i) => {
    const area = data.municipalities[municipality]!;
    pop[i] = residents; p65[i] = aged; language[i] = residents * area.foreign_language; rate[i] = area.gp_visits_per_1000;
    dens[i] = density(residents, data.cell_km); muni[i] = municipality;
  });
  const stationIndex = new SpatialIndex(data.stations);
  const near = new Int32Array(n * k).fill(-1), nearKm = new Float32Array(n * k).fill(Infinity);
  data.cells.forEach(([lon, lat], i) => {
    let found: number[] = [];
    for (let rings = 1; found.length < k && rings < 40; rings *= 2) found = stationIndex.around(lon, lat, rings);
    const ranked = found.map(j => ({ j, d: km(lon, lat, data.stations[j]!.lon, data.stations[j]!.lat) })).sort((a, b) => a.d - b.d).slice(0, k);
    ranked.forEach(({ j, d }, r) => { near[i * k + r] = j; nearKm[i * k + r] = d; });
  });
  const cellIndex = new SpatialIndex(data.cells.map(([lon, lat]) => ({ lon, lat })));
  const stopStart = new Int32Array(data.stops.length + 1), stopMuni = new Uint16Array(data.stops.length), stopCell: number[] = [], stopKm: number[] = [];
  data.stops.forEach((stop, s) => {
    stopStart[s] = stopCell.length;
    let closest = Infinity;
    for (const i of cellIndex.around(stop.lon, stop.lat, 2)) {
      const d = km(stop.lon, stop.lat, data.cells[i]![0], data.cells[i]![1]);
      if (d <= 45) { stopCell.push(i); stopKm.push(d); }
      if (d < closest) { closest = d; stopMuni[s] = muni[i]!; }
    }
  });
  stopStart[data.stops.length] = stopCell.length;
  const capacity = new Float64Array(m), share = new Float32Array(k);
  let visits = 0, residents = 0;
  for (let i = 0; i < n; i++) {
    split(near, nearKm, k, i, () => true, share, 0);
    for (let r = 0; r < k; r++) if (share[r]) capacity[near[i * k + r]!]! += pop[i]! * rate[i]! / 1000 * share[r]!;
    visits += pop[i]! * rate[i]! / 1000; residents += pop[i]!;
  }
  return { data, n, m, pop, p65, language, rate, density: dens, muni, near, nearKm, k, stopStart, stopCell: Int32Array.from(stopCell), stopKm: Float32Array.from(stopKm), stopMuni,
    capacity, national: visits / residents * 1000 };
}

// ---- One week's state ---------------------------------------------------------------------------------
export type Week = {
  slow: number; busStrike: boolean;
  /** Nearest open station per square (-1 if none of the K nearest is open). */ nearest: Int32Array;
  /** Share of each square's residents using each of its K nearest stations (n × K). */ share: Float32Array;
  carMin: Float32Array; noCarMin: Float32Array;
  /** GP visits a year within reach per 1,000 residents (E2SFCA). */ access: Float64Array;
  capacity: Float64Array; reach: Float64Array; demand: Float64Array;
  /** National visits per 1,000 residents in this week: "below average" is measured from this line. */ target: number;
};
export type Variation = { slow?: number; muniDemand?: Float64Array; capacityFactor?: Float64Array; extraClosed?: number; extraCapacity?: { station: number; visits: number } };

export function week(p: Prepared, s: Settings, v: Variation = {}): Week {
  const slow = (s.storm ? travel.stormFactor : 1) * (v.slow ?? 1), K = p.k;
  const closed = new Set(s.closed);
  if (v.extraClosed !== undefined) closed.add(v.extraClosed);
  const demand = new Float64Array(p.n);
  for (let i = 0; i < p.n; i++) demand[i] = p.pop[i]! * (v.muniDemand?.[p.muni[i]!] ?? 1);
  const capacity = new Float64Array(p.m);
  for (let j = 0; j < p.m; j++) capacity[j] = closed.has(p.data.stations[j]!.id) ? 0 : p.capacity[j]! * (v.capacityFactor?.[j] ?? 1);
  if (v.extraCapacity) capacity[v.extraCapacity.station]! += v.extraCapacity.visits;
  const nearest = new Int32Array(p.n).fill(-1), carMin = new Float32Array(p.n), noCarMin = new Float32Array(p.n);
  const reach = new Float64Array(p.m), weights = new Float32Array(p.n * K), share = new Float32Array(p.n * K);
  const open = (j: number) => capacity[j]! > 0;
  for (let i = 0; i < p.n; i++) {
    split(p.near, p.nearKm, K, i, open, share, i * K);
    const from = p.density[i]! as Density;
    let first = true;
    for (let r = 0; r < K; r++) {
      const j = p.near[i * K + r]!;
      if (j < 0) break;
      if (!capacity[j]) continue;
      const d = p.nearKm[i * K + r]!, minutes = carMinutes(d, from, slow);
      if (first) { nearest[i] = j; carMin[i] = minutes; noCarMin[i] = noCarMinutes(d, from, slow, s.busStrike); first = false; }
      const w = decay(minutes);
      weights[i * K + r] = w; reach[j]! += demand[i]! * w;
    }
    if (first) { carMin[i] = 999; noCarMin[i] = 999; }
  }
  const access = new Float64Array(p.n);
  let supply = 0, people = 0;
  for (let j = 0; j < p.m; j++) supply += capacity[j]!;
  for (let i = 0; i < p.n; i++) {
    people += demand[i]!;
    let a = 0;
    for (let r = 0; r < K; r++) { const w = weights[i * K + r]!; if (w) { const j = p.near[i * K + r]!; a += capacity[j]! / reach[j]! * w; } }
    access[i] = a * 1000;
  }
  return { slow, busStrike: s.busStrike, nearest, share, carMin, noCarMin, access, capacity, reach, demand, target: supply / people * 1000 };
}

// ---- Headline numbers -----------------------------------------------------------------------------------
export type Summary = { residents: number; farByCar: number; far65NoCar: number; belowCapacity: number; longWaits: number; language: number; languageFar: number; national: number };
export function summary(p: Prepared, w: Week, county?: number): Summary {
  let residents = 0, farByCar = 0, far65NoCar = 0, belowCapacity = 0, longWaits = 0, language = 0, languageFar = 0, visits = 0;
  for (let i = 0; i < p.n; i++) {
    const area = p.data.municipalities[p.muni[i]!]!;
    if (county !== undefined && area.county !== county) continue;
    const people = p.pop[i]!;
    residents += people; language += p.language[i]!; visits += people * w.access[i]! / 1000;
    if (w.carMin[i]! > 30) { farByCar += people; languageFar += p.language[i]!; }
    if (w.noCarMin[i]! > 30) far65NoCar += p.p65[i]!;
    if (w.access[i]! < 0.8 * w.target) belowCapacity += people;
    if ((area.wait_over_7_days ?? 0) > 50) longWaits += people;
  }
  return { residents, farByCar, far65NoCar, belowCapacity, longWaits, language, languageFar, national: county === undefined ? w.target : visits / residents * 1000 };
}

// ---- Gains of one resource at each candidate place --------------------------------------------------------
export const candidates = (p: Prepared, r: Resource) => r === "clinic" ? p.data.stops.length : p.m;
export function stationName(data: TwinData, j: number) {
  const station = data.stations[j]!, place = data.municipalities[station.muni]!.name;
  return /^(terveysasema|hälsostation|terveyskeskus)$/i.test(station.name) ? `${station.name}, ${place}` : station.name;
}
export function candidatePlace(p: Prepared, r: Resource, c: number) {
  if (r === "clinic") { const stop = p.data.stops[c]!; return { name: `${stop.name}, ${p.data.municipalities[p.stopMuni[c]!]!.name}`, lon: stop.lon, lat: stop.lat, muni: p.stopMuni[c]! }; }
  const station = p.data.stations[c]!;
  return { name: stationName(p.data, c), lon: station.lon, lat: station.lat, muni: station.muni };
}

/** People helped by a mobile clinic stop in one square: residents under 65 and drivers by car, the rest without a car. */
function clinicBenefit(p: Prepared, w: Week, s: Settings, i: number, d: number) {
  const from = p.density[i]! as Density, people = w.demand[i]!, ratio = p.pop[i]! ? people / p.pop[i]! : 0;
  const older = p.p65[i]! * ratio, younger = people - older;
  let helped = 0;
  if (w.carMin[i]! > 30 && carMinutes(d, from, w.slow) <= 30) helped += younger + older * (1 - s.noCar65);
  if (w.noCarMin[i]! > 30 && noCarMinutes(d, from, w.slow, w.busStrike) <= 30) helped += older * s.noCar65;
  return helped;
}

/** Gain of placing the resource at every candidate, in the resource's own unit. */
export function gains(p: Prepared, w: Week, s: Settings, r: Resource): Float64Array {
  const K = p.k;
  if (r === "clinic") {
    const out = new Float64Array(p.data.stops.length);
    for (let c = 0; c < out.length; c++) for (let q = p.stopStart[c]!; q < p.stopStart[c + 1]!; q++) out[c]! += clinicBenefit(p, w, s, p.stopCell[q]!, p.stopKm[q]!);
    return out;
  }
  const out = new Float64Array(p.m);
  if (r === "interpreter") {
    for (let i = 0; i < p.n; i++) {
      if (p.language[i]! < 0.5) continue;
      const speakers = p.language[i]! * (p.pop[i]! ? w.demand[i]! / p.pop[i]! : 0), from = p.density[i]! as Density;
      for (let r = 0; r < K; r++) {
        const sh = w.share[i * K + r]!;
        if (sh && carMinutes(p.nearKm[i * K + r]!, from, w.slow) <= 30) out[p.near[i * K + r]!]! += speakers * sh;
      }
    }
    return out;
  }
  // GP: extra visits at j raise reachable visits by ΔS·w_ij / reach_j at every square that can reach j.
  // Only visits that lift people towards the national average count, weighted by how far below it they are,
  // so a GP ranks highest where the people who would see them have the fewest visits today.
  for (let i = 0; i < p.n; i++) {
    const shortfall = w.target - w.access[i]!;
    if (shortfall <= 0) continue;
    const from = p.density[i]! as Density;
    for (let r2 = 0; r2 < K; r2++) {
      const j = p.near[i * K + r2]!;
      if (j < 0 || !w.capacity[j] || !w.reach[j]) continue;
      const weight = decay(carMinutes(p.nearKm[i * K + r2]!, from, w.slow));
      if (!weight) continue;
      out[j]! += w.demand[i]! * Math.min(s.gpVisits * weight / w.reach[j]! * 1000, shortfall) / 1000 * (shortfall / w.target);
    }
  }
  return out;
}

/** The expected week with the resource in place, and which squares it helps (for the map). */
export function applyResource(p: Prepared, s: Settings, before: Week, r: Resource, c: number) {
  const helped: { cell: number; amount: number }[] = [];
  if (r === "gp") {
    const next = week(p, s, { extraCapacity: { station: c, visits: s.gpVisits } });
    let visits = 0, weighted = 0;
    for (let i = 0; i < p.n; i++) {
      const added = (next.access[i]! - before.access[i]!) * before.demand[i]! / 1000;
      if (added > 0) { visits += added; weighted += added * before.access[i]!; }
      const gain = Math.min(next.access[i]! - before.access[i]!, Math.max(0, before.target - before.access[i]!));
      if (gain > 0.5) helped.push({ cell: i, amount: before.demand[i]! * gain / 1000 });
    }
    // Visits a year per 1,000 residents that the people seeing the new GP reach today.
    return { week: { ...next, target: before.target }, helped, recipientsAccess: visits ? weighted / visits : 0 };
  }
  if (r === "interpreter") {
    for (let i = 0; i < p.n; i++) for (let r = 0; r < p.k; r++) {
      const sh = before.share[i * p.k + r]!;
      if (p.near[i * p.k + r] === c && sh && carMinutes(p.nearKm[i * p.k + r]!, p.density[i]! as Density, before.slow) <= 30 && p.language[i]! * sh >= 1)
        helped.push({ cell: i, amount: p.language[i]! * sh });
    }
    return { week: before, helped, recipientsAccess: 0 };
  }
  const carMin = Float32Array.from(before.carMin), noCarMin = Float32Array.from(before.noCarMin);
  for (let q = p.stopStart[c]!; q < p.stopStart[c + 1]!; q++) {
    const i = p.stopCell[q]!, d = p.stopKm[q]!, from = p.density[i]! as Density;
    const benefit = clinicBenefit(p, before, s, i, d);
    if (benefit > 0) helped.push({ cell: i, amount: benefit });
    carMin[i] = Math.min(carMin[i]!, carMinutes(d, from, before.slow));
    noCarMin[i] = Math.min(noCarMin[i]!, noCarMinutes(d, from, before.slow, before.busStrike));
  }
  return { week: { ...before, carMin, noCarMin }, helped, recipientsAccess: 0 };
}

// ---- Monte Carlo ------------------------------------------------------------------------------------
/** Deterministic pseudo-random numbers, so a run can be repeated and tested. */
export function rng(seed: number) {
  let state = seed >>> 0;
  return () => { state = (state + 0x6d2b79f5) >>> 0; let t = state; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}
const gaussian = (random: () => number) => Math.sqrt(-2 * Math.log(1 - random())) * Math.cos(2 * Math.PI * random());
const weekKinds = [{ slow: 1, label: "An ordinary week" }, { slow: 1, label: "An ordinary week" }, { slow: 1.1, label: "A week of slow roads" }, { slow: 1.3, label: "A snowy week" }];

export type Simulation = { resource: Resource; draws: number; scenarios: number; gains: Float32Array[]; mean: Float64Array; low: Float64Array; high: Float64Array };
export type Progress = { draw: number; draws: number; scenarios: number; label: string; leader: number };

/**
 * Simulates `draws` uncertain weeks. Each week varies travel speed, demand per municipality (±8%), GP
 * availability per station (±10%) and has a 15% chance that one station closes unexpectedly. Every
 * candidate place is scored under the same week, so differences between places are fair.
 */
export function* simulate(p: Prepared, s: Settings, r: Resource, draws: number, seed: number): Generator<Progress, Simulation> {
  const random = rng(seed), count = candidates(p, r);
  const all = Array.from({ length: count }, () => new Float32Array(draws));
  const total = new Float64Array(count);
  for (let draw = 0; draw < draws; draw++) {
    const kind = weekKinds[Math.floor(random() * weekKinds.length)]!;
    const muniDemand = Float64Array.from(p.data.municipalities, () => Math.max(0.7, 1 + 0.08 * gaussian(random)));
    const capacityFactor = Float64Array.from({ length: p.m }, () => Math.max(0.6, 1 + 0.1 * gaussian(random)));
    const closedIndex = random() < 0.15 ? Math.floor(random() * p.m) : -1;
    const w = week(p, s, { slow: kind.slow, muniDemand, capacityFactor, extraClosed: closedIndex >= 0 ? p.data.stations[closedIndex]!.id : undefined });
    const g = gains(p, w, s, r);
    let leader = 0;
    for (let c = 0; c < count; c++) { all[c]![draw] = g[c]!; total[c]! += g[c]!; if (total[c]! > total[leader]!) leader = c; }
    yield { draw: draw + 1, draws, scenarios: (draw + 1) * count, leader,
      label: closedIndex >= 0 ? `${kind.label}, ${stationName(p.data, closedIndex)} unexpectedly closed` : kind.label };
  }
  const mean = new Float64Array(count), low = new Float64Array(count), high = new Float64Array(count);
  all.forEach((values, c) => {
    const sorted = Float32Array.from(values).sort();
    mean[c] = total[c]! / draws; low[c] = sorted[Math.floor(0.05 * (draws - 1))]!; high[c] = sorted[Math.ceil(0.95 * (draws - 1))]!;
  });
  return { resource: r, draws, scenarios: draws * count, gains: all, mean, low, high };
}
export function runSimulation(p: Prepared, s: Settings, r: Resource, draws: number, seed: number) {
  const steps = simulate(p, s, r, draws, seed);
  for (;;) { const step = steps.next(); if (step.done) return step.value; }
}

export type Ranked = { index: number; name: string; mean: number; low: number; high: number; bestShare: number; county: number; muni: number; lon: number; lat: number };
/** Candidates ranked by mean gain, optionally within one county; `bestShare` is the share of simulated weeks it ranked in the top 3. */
export function rank(p: Prepared, sim: Simulation, county?: number): Ranked[] {
  const pool: number[] = [];
  for (let c = 0; c < sim.mean.length; c++) if (county === undefined || p.data.municipalities[candidatePlace(p, sim.resource, c).muni]!.county === county) pool.push(c);
  const wins = new Map<number, number>();
  for (let draw = 0; draw < sim.draws; draw++) {
    const top: number[] = [];
    for (const c of pool) {
      top.push(c); top.sort((a, b) => sim.gains[b]![draw]! - sim.gains[a]![draw]!);
      if (top.length > 3) top.pop();
    }
    for (const c of top) wins.set(c, (wins.get(c) ?? 0) + 1);
  }
  return pool.map(c => {
    const place = candidatePlace(p, sim.resource, c);
    return { index: c, name: place.name, mean: sim.mean[c]!, low: sim.low[c]!, high: sim.high[c]!, bestShare: (wins.get(c) ?? 0) / sim.draws,
      county: p.data.municipalities[place.muni]!.county, muni: place.muni, lon: place.lon, lat: place.lat };
  }).sort((a, b) => b.mean - a.mean);
}

// ---- What a closure does ----------------------------------------------------------------------------------
export function closureImpact(p: Prepared, before: Week, afterWeek: Week, station: number) {
  const K = p.k;
  let moved = 0, nowFar = 0, extraMinutes = 0;
  const destinations = new Map<number, number>();
  for (let i = 0; i < p.n; i++) {
    let used = 0;
    for (let r = 0; r < K; r++) if (p.near[i * K + r] === station) used = before.share[i * K + r]!;
    if (!used) continue;
    const people = p.pop[i]! * used;
    moved += people; extraMinutes += people * Math.max(0, Math.min(120, afterWeek.carMin[i]! - before.carMin[i]!));
    if (before.carMin[i]! <= 30 && afterWeek.carMin[i]! > 30) nowFar += people;
    for (let r = 0; r < K; r++) { const sh = afterWeek.share[i * K + r]!; if (sh) { const j = p.near[i * K + r]!; destinations.set(j, (destinations.get(j) ?? 0) + people * sh); } }
  }
  destinations.delete(station);
  const to = [...destinations.entries()].sort((a, b) => b[1] - a[1]).slice(0, 3).map(([j, people]) => ({ station: j, people }));
  return { moved, nowFar, averageExtraMinutes: moved ? extraMinutes / moved : 0, to, lostVisits: before.capacity[station]! };
}
