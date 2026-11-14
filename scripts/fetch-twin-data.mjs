#!/usr/bin/env node
// Regenerates apps/crm-web/src/lib/twin-snapshot.json, the public geography behind the CRM digital twin.
// Every input is a published area-level aggregate. Nothing about patients, referrals, nationality or
// immigration status is requested or stored.
//   - Helsinki health stations, opening hours and wheelchair accessibility: City of Helsinki Service Map
//   - 250 m population grid: HSY (Helsinki Region Environmental Services), 31.12.2024
//   - Sub-district age and mother-tongue counts: City of Helsinki Aluesarjat, 2025
//   - Public libraries (candidate mobile-clinic stops): City of Helsinki Service Map
import { writeFileSync } from "node:fs";
import { weeklyHours } from "./twin-hours.mjs";

const SERVICE_MAP = "https://api.hel.fi/servicemap/v2/unit/";
const HSY_WFS = "https://kartta.hsy.fi/geoserver/wfs";
const HEL_WFS = "https://kartta.hel.fi/ws/geoserver/avoindata/wfs";
const GRID_LAYER = "asuminen_ja_maankaytto:Vaestotietoruudukko_2024";
const AREA_LAYER = "avoindata:Aluesarjat_vaestorakenne_vr_2025";
const HEALTH_STATIONS = 703, PUBLIC_LIBRARIES = 813;
const out = new URL("../apps/crm-web/src/lib/twin-snapshot.json", import.meta.url);

async function json(url) {
  const response = await fetch(url, { signal: AbortSignal.timeout(60_000) });
  if (!response.ok) throw new Error(`${url} returned HTTP ${response.status}`);
  return response.json();
}
const wfs = (base, layer) => json(`${base}?service=WFS&version=2.0.0&request=GetFeature&typeNames=${layer}&outputFormat=application/json&srsName=EPSG:4326`);
async function units(service) {
  const results = [];
  let next = `${SERVICE_MAP}?service=${service}&municipality=helsinki&page_size=100&include=connections`;
  while (next) { const page = await json(next); results.push(...page.results); next = page.next; }
  return results;
}
const round = (value, digits) => Number(value.toFixed(digits));
const rings = geometry => geometry.type === "Polygon" ? [geometry.coordinates] : geometry.coordinates;
function inside([x, y], polygons) {
  return polygons.some(polygon => {
    let hit = false;
    for (const ring of polygon) for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      const [xi, yi] = ring[i], [xj, yj] = ring[j];
      if ((yi > y) !== (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) hit = !hit;
    }
    return hit;
  });
}

const shortName = name => (name.split("/").pop() ?? name).trim();

const [areasGeo, gridGeo, stationUnits, libraryUnits] = await Promise.all([
  wfs(HEL_WFS, AREA_LAYER), wfs(HSY_WFS, GRID_LAYER), units(HEALTH_STATIONS), units(PUBLIC_LIBRARIES),
]);

// The layer can list a sub-district more than once (one feature per polygon part): merge by id.
const areaByID = new Map();
for (const feature of areasGeo.features) {
  if (!/^91\d{7}$/.test(String(feature.properties.kokotun)) || !(feature.properties.vr_vakiy > 0)) continue;
  const known = areaByID.get(feature.properties.osa_alueid);
  if (known) known.geometry = { type: "MultiPolygon", coordinates: [...rings(known.geometry), ...rings(feature.geometry)] };
  else areaByID.set(feature.properties.osa_alueid, { ...feature, geometry: { ...feature.geometry } });
}
const areas = [...areaByID.values()]
  .map(feature => {
    const p = feature.properties;
    const sum = keys => keys.reduce((total, key) => total + (p[key] ?? 0), 0);
    return {
      polygons: rings(feature.geometry),
      record: {
        id: p.osa_alueid, name: p.nimi, population: p.vr_vakiy,
        // Mother tongue other than Finnish, Sami or Swedish: a proxy for possible language support.
        foreign_language: round(p.vr_kiel_vier / p.vr_vakiy, 3),
        // Residents aged 75+: a proxy for needing a step-free route.
        aged_75: round(sum(["vr_75_79", "vr_80_84", "vr_85_"]) / p.vr_vakiy, 3),
      },
    };
  });
if (areas.length < 100) throw new Error(`Only ${areas.length} Helsinki sub-districts returned`);

const cells = [];
for (const feature of gridGeo.features) {
  const residents = feature.properties.asukkaita;
  if (!(residents > 0)) continue;
  const ring = rings(feature.geometry)[0][0].slice(0, -1);
  const centre = [ring.reduce((t, [x]) => t + x, 0) / ring.length, ring.reduce((t, [, y]) => t + y, 0) / ring.length];
  const area = areas.findIndex(item => inside(centre, item.polygons));
  if (area >= 0) cells.push([round(centre[0], 5), round(centre[1], 5), residents, area]);
}
if (cells.length < 1000) throw new Error(`Only ${cells.length} populated Helsinki grid cells`);

const stations = stationUnits.filter(unit => unit.location?.coordinates).map(unit => {
  const text = unit.connections.find(item => item.section_type === "OPENING_HOURS" && /\d\.\d{2}/.test(item.name?.fi ?? ""))?.name?.fi ?? "";
  const shortcomings = unit.accessibility_shortcoming_count ?? {};
  return {
    id: unit.id, name: shortName(unit.name.fi), full_name: unit.name.fi,
    lon: round(unit.location.coordinates[0], 5), lat: round(unit.location.coordinates[1], 5),
    hours: weeklyHours(text),
    // Shortcomings the city's accessibility survey records for wheelchair users; null when no survey is published.
    wheelchair_shortcomings: Object.keys(shortcomings).length ? shortcomings.wheelchair ?? 0 : null,
    url: unit.www?.en ?? unit.www?.fi ?? null,
  };
}).filter(station => station.hours.day > 0);
if (stations.length < 15) throw new Error(`Only ${stations.length} health stations with opening hours`);

// Candidate mobile-clinic stops. Suomenlinna is excluded: it has no road access for a vehicle.
const libraries = libraryUnits.filter(unit => unit.location?.coordinates && !/kirjastoauto|automaatti|suomenlinna/i.test(unit.name.fi))
  .map(unit => ({ id: unit.id, name: unit.name.en ?? unit.name.fi, lon: round(unit.location.coordinates[0], 5), lat: round(unit.location.coordinates[1], 5) }));

const snapshot = {
  generated_at: new Date().toISOString(),
  region: "City of Helsinki",
  sources: [
    { id: "stations", title: "Helsinki Service Map: health stations, opening hours, accessibility", publisher: "City of Helsinki", licence: "CC BY 4.0", url: "https://palvelukartta.hel.fi/" },
    { id: "grid", title: "Population grid 250 m, 31.12.2024", publisher: "HSY", licence: "CC BY 4.0", url: "https://www.hsy.fi/en/environmental-information/open-data/" },
    { id: "areas", title: "Aluesarjat: population by sub-district, age and mother tongue, 2025", publisher: "City of Helsinki", licence: "CC BY 4.0", url: "https://stat.hel.fi/" },
    { id: "libraries", title: "Helsinki Service Map: public libraries", publisher: "City of Helsinki", licence: "CC BY 4.0", url: "https://palvelukartta.hel.fi/" },
  ],
  cell_size_m: 250,
  areas: areas.map(item => item.record),
  // [longitude, latitude, residents, sub-district index]
  cells,
  stations,
  libraries,
};
writeFileSync(out, `${JSON.stringify(snapshot)}\n`);
console.log(`Wrote ${cells.length} cells, ${areas.length} sub-districts, ${stations.length} stations, ${libraries.length} libraries to ${out.pathname}`);
