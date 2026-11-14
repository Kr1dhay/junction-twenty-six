#!/usr/bin/env node
// Regenerates apps/crm-web/src/lib/twin-snapshot.json: the public geography behind the CRM digital twin
// for mainland Finland. Every input is a published aggregate or a public place. Nothing about patients,
// referrals, nationality, citizenship or immigration status is requested or stored.
//   - Residents and residents aged 65+ per 1 km square, 31.12.2024: Statistics Finland population grid
//   - Mother tongue by municipality, 2025: Statistics Finland StatFin 11rm (foreign-language speakers)
//   - GP visits per 1,000 residents and waits over 7 days, by municipality: THL Sotkanet (4123, 6411)
//   - Health stations and opening hours: Suomi.fi Service Catalogue (PTV), gaps filled from OpenStreetMap
//   - Villages and towns (candidate mobile-clinic stops): OpenStreetMap
// Åland is excluded: its health care is run separately by ÅHS.
import { writeFileSync } from "node:fs";

const UA = { "User-Agent": "edgecare-digital-twin/0.1 (public-data snapshot)" };
const GRID = "https://geo.stat.fi/geoserver/vaestoruutu/wfs?service=WFS&version=2.0.0&request=GetFeature&typeNames=vaestoruutu:vaki2024_1km&outputFormat=application/json&propertyName=kunta,vaesto,ika_65_,xkoord,ykoord";
const STATFIN = "https://pxdata.stat.fi/PxWeb/api/v1/fi/StatFin/vaerak/11rm.px";
const SOTKANET = "https://sotkanet.fi/rest/1.1";
const PTV = "https://api.palvelutietovaranto.suomi.fi/api/v11";
const OVERPASS = "https://overpass-api.de/api/interpreter";
const GP_VISITS = 4123, WAIT_OVER_7_DAYS = 6411;
const CELL_M = 2000;
const ALAND = new Set(["035", "043", "060", "062", "065", "076", "170", "295", "318", "417", "438", "478", "736", "766", "771", "941"]);
const out = new URL("../apps/crm-web/src/lib/twin-snapshot.json", import.meta.url);

async function json(url, init = {}, attempts = 4) {
  for (let attempt = 1; ; attempt++) {
    try {
      const response = await fetch(url, { ...init, headers: { ...UA, ...init.headers }, signal: AbortSignal.timeout(240_000) });
      if (!response.ok) throw new Error(`${url.slice(0, 90)} returned HTTP ${response.status}`);
      return await response.json();
    } catch (error) {
      if (attempt >= attempts) throw error;
      await new Promise(resolve => setTimeout(resolve, 5000 * attempt));
    }
  }
}
const overpass = query => json(OVERPASS, { method: "POST", body: new URLSearchParams({ data: `[out:json][timeout:180];area["ISO3166-1"="FI"][admin_level=2]->.fi;${query}` }) });
const round = (value, digits) => Number(value.toFixed(digits));

/** ETRS-TM35FIN (EPSG:3067) to WGS84 longitude and latitude. */
function tm35(E, N) {
  const a = 6378137, f = 1 / 298.257222101, k0 = 0.9996, lon0 = 27 * Math.PI / 180;
  const n = f / (2 - f), A1 = a / (1 + n) * (1 + n * n / 4 + n ** 4 / 64), e = Math.sqrt(f * (2 - f));
  const h = [n / 2 - 2 / 3 * n * n + 37 / 96 * n ** 3, n * n / 48 + n ** 3 / 15, 17 / 480 * n ** 3];
  const xi = N / (A1 * k0), eta = (E - 500000) / (A1 * k0);
  let xi1 = xi, eta1 = eta;
  h.forEach((hk, k) => { xi1 -= hk * Math.sin(2 * (k + 1) * xi) * Math.cosh(2 * (k + 1) * eta); eta1 -= hk * Math.cos(2 * (k + 1) * xi) * Math.sinh(2 * (k + 1) * eta); });
  const beta = Math.asin(Math.sin(xi1) / Math.cosh(eta1)), l = Math.asin(Math.tanh(eta1) / Math.cos(beta));
  const Q = Math.asinh(Math.tan(beta));
  let Q1 = Q;
  for (let k = 0; k < 6; k++) Q1 = Q + e * Math.atanh(e * Math.tanh(Q1));
  return [(lon0 + l) * 180 / Math.PI, Math.atan(Math.sinh(Q1)) * 180 / Math.PI];
}
const metres = (a, b) => 111_320 * Math.hypot((a[0] - b[0]) * Math.cos(a[1] * Math.PI / 180), a[1] - b[1]);

// ---- Population grid → 2 km squares ---------------------------------------------------------------
const grid = (await json(GRID)).features.map(feature => feature.properties).filter(p => p.vaesto > 0 && !ALAND.has(p.kunta));
const known = new Map(); // per municipality: residents and 65+ in squares where the age split is published
for (const p of grid) if (p.ika_65_ >= 0) { const k = known.get(p.kunta) ?? [0, 0]; k[0] += p.vaesto; k[1] += p.ika_65_; known.set(p.kunta, k); }
const squares = new Map();
for (const p of grid) {
  const key = `${Math.floor(p.xkoord / CELL_M)}:${Math.floor(p.ykoord / CELL_M)}`;
  const square = squares.get(key) ?? { x: Math.floor(p.xkoord / CELL_M), y: Math.floor(p.ykoord / CELL_M), pop: 0, p65: 0, byMuni: new Map() };
  // Statistics Finland suppresses the age split in squares with fewer than 10 residents: use the municipality's share there.
  const share = known.get(p.kunta) ? known.get(p.kunta)[1] / known.get(p.kunta)[0] : 0.25;
  square.pop += p.vaesto; square.p65 += p.ika_65_ >= 0 ? p.ika_65_ : p.vaesto * share;
  square.byMuni.set(p.kunta, (square.byMuni.get(p.kunta) ?? 0) + p.vaesto);
  squares.set(key, square);
}
if (squares.size < 20_000) throw new Error(`Only ${squares.size} populated 2 km squares`);

// ---- Municipalities, wellbeing services counties and their published figures ------------------------
const regions = await json(`${SOTKANET}/regions`);
const counties = regions.filter(region => region.category === "HYVINVOINTIALUE");
const sotkaMuni = new Map(regions.filter(region => region.category === "KUNTA").map(region => [region.code, region]));
async function indicator(id) {
  const rows = await json(`${SOTKANET}/json?indicator=${id}&years=2023&years=2024&years=2025&genders=total`);
  const latest = new Map();
  for (const row of rows) if (row.value !== undefined && (latest.get(row.region)?.year ?? 0) < row.year) latest.set(row.region, row);
  return latest;
}
const [visits, waits] = [await indicator(GP_VISITS), await indicator(WAIT_OVER_7_DAYS)];

const meta = await json(STATFIN);
const code = prefix => meta.variables.find(variable => variable.code.startsWith(prefix)).code;
const year = meta.variables.find(variable => variable.code === "timeperiod_y").values.at(-1);
const language = await json(STATFIN, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ query: [
  { code: code("alue"), selection: { filter: "all", values: ["*"] } },
  { code: code("kieli"), selection: { filter: "item", values: ["SSS", "02"] } },
  { code: code("sukupuoli"), selection: { filter: "item", values: ["SSS"] } },
  { code: "timeperiod_y", selection: { filter: "item", values: [year] } },
], response: { format: "json-stat2" } }) });
const areaIndex = language.dimension[code("alue")].category.index, areaLabel = language.dimension[code("alue")].category.label;
const languageOf = new Map();
for (const [areaCode, k] of Object.entries(areaIndex)) {
  if (!areaCode.startsWith("KU")) continue;
  const total = language.value[k * 2], foreign = language.value[k * 2 + 1];
  languageOf.set(areaCode.slice(2), { name: areaLabel[areaCode], share: total ? foreign / total : 0 });
}

const muniCodes = [...new Set(grid.map(p => p.kunta))].sort();
const countyIndex = new Map(), countyList = [];
const municipalities = muniCodes.map(muniCode => {
  const sotka = sotkaMuni.get(muniCode), lang = languageOf.get(muniCode);
  const county = counties.find(item => sotka?.memberOf.includes(item.id));
  if (county && !countyIndex.has(county.id)) { countyIndex.set(county.id, countyList.length); countyList.push({ name: county.title.en.replace(/ wellbeing services county$/, ""), name_fi: county.title.fi }); }
  const figure = (table, digits) => {
    const value = table.get(sotka?.id)?.value ?? table.get(county?.id)?.value;
    return value === undefined ? null : round(value, digits);
  };
  return { code: muniCode, name: lang?.name ?? sotka?.title.fi ?? muniCode, county: county ? countyIndex.get(county.id) : -1,
    foreign_language: round(lang?.share ?? 0, 3), gp_visits_per_1000: figure(visits, 0), wait_over_7_days: figure(waits, 1) };
});
const muniAt = new Map(municipalities.map((item, k) => [item.code, k]));
if (municipalities.some(item => item.county < 0 || item.gp_visits_per_1000 === null)) throw new Error("Municipality without a county or GP visit rate");

const cells = [...squares.values()].map(square => {
  const [lon, lat] = tm35(square.x * CELL_M + CELL_M / 2, square.y * CELL_M + CELL_M / 2);
  const muni = [...square.byMuni.entries()].sort((a, b) => b[1] - a[1])[0][0];
  return [round(lon, 4), round(lat, 4), square.pop, Math.round(square.p65), muniAt.get(muni)];
});
const nearestMuni = point => cells.reduce((best, cell) => { const d = metres(point, cell); return d < best.d ? { d, muni: cell[4] } : best; }, { d: Infinity, muni: 0 }).muni;

// ---- Health stations: Suomi.fi Service Catalogue, then OpenStreetMap where the catalogue has a gap ----------
const STATION = /terveysasem|terveyskeskus|hälsostation|hälsocentral|sote-keskus|sote-asema|sosiaali- ja terveys|hyvinvointiasema|hyvinvointikeskus|lähiklinikka|terveyspiste/i;
const SUB_UNIT = /hammas|tandvård|suun |fysiot|mielenterv|päihde|neuvola|rådgivning|osasto|kuntoutu|laboratori|röntgen|kuvanta|olka|lähitori|sosiaalipalvel|sosiaalityö|ehkäisy|perhesuun|rokot|kotihoi|kotisairaan|apuväline|jalkaterap|puheterap|toimintaterap|ravitsem|psykiatr|lasten|opiskel|koulu|äitiys|seksuaal|diabet|muisti|vammais|palveluasu|työterve|perhekeskus|nuorten|talous|toimisto|kirjaamo|asiakasohjaus|eläinlääk|terveysvalvon/i;
const NOT_PUBLIC = /terveystoimi|dragsvik|varuskun|prikaati|santahamin|parolannumm|vekaranjärv|luonetjärv|upinniem|niinisal|työterve|mehiläinen|terveystalo|pihlajalinna|attendo|aava|diacor|yksityi/i;
const days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
const hourOf = text => { const [h, m] = text.split(":").map(Number); return h + m / 60; };
/** Weekly hours open on weekdays 8–16 ("day") and outside them ("extended"), from structured service hours. */
function weeklyHours(serviceHours) {
  let day = 0, extended = 0;
  for (const entry of serviceHours.filter(item => item.serviceHourType === "DaysOfTheWeek" && !item.isClosed && item.validForNow !== false)) {
    for (const open of entry.openingHour ?? []) {
      const from = days.indexOf(open.dayFrom), to = open.dayTo ? days.indexOf(open.dayTo) : from;
      if (from < 0) continue;
      for (let d = from; d <= (to < from ? from : to); d++) {
        const start = hourOf(open.from), end = hourOf(open.to) || 24;
        const inside = d < 5 ? Math.max(0, Math.min(end, 16) - Math.max(start, 8)) : 0;
        day += inside; extended += Math.max(0, end - start) - inside;
      }
    }
  }
  return day + extended ? { day: round(day, 1), extended: round(extended, 1) } : null;
}
const listing = [];
for (let page = 1, pages = 1; page <= pages; page++) {
  const result = await json(`${PTV}/ServiceChannel/type/ServiceLocation?page=${page}`);
  pages = result.pageCount; listing.push(...result.itemList);
}
const candidates = listing.filter(item => { const first = (item.name ?? "").split(",")[0]; return STATION.test(first) && !SUB_UNIT.test(first) && !NOT_PUBLIC.test(item.name); });
const details = [];
for (let k = 0; k < candidates.length; k += 50) details.push(...await json(`${PTV}/ServiceChannel/list?guids=${candidates.slice(k, k + 50).map(item => item.id).join(",")}`));
const stations = [];
const addStation = station => { if (stations.every(other => metres(station.at, other.at) > (station.source === "osm" ? 500 : 250))) stations.push(station); };
for (const detail of details.filter(item => item.publishingStatus === "Published")
  .map(item => ({ item, name: item.serviceChannelNames.find(n => n.language === "fi")?.value ?? item.serviceChannelNames[0].value }))
  .sort((a, b) => a.name.length - b.name.length)) {
  const address = detail.item.addresses.find(a => a.type === "Location" && a.streetAddress?.latitude)?.streetAddress;
  if (!address) continue;
  const at = tm35(Number(address.longitude), Number(address.latitude));
  const muni = muniAt.get(address.municipality?.code);
  if (muni === undefined) continue; // Åland or outside the grid
  addStation({ name: detail.name.split(",")[0].trim(), at, muni, hours: weeklyHours(detail.item.serviceHours ?? []), source: "ptv" });
}
const fromCatalogue = stations.length;
const names = '"name"~"terveysasema|terveyskeskus|hälsostation|hälsocentral|sote-keskus|sote-asema|sosiaali- ja terveys|hyvinvointikeskus|hyvinvointiasema|lähiklinikka",i';
const osm = (await overpass(`(nwr(area.fi)["amenity"~"^(clinic|doctors|hospital)$"][${names}];nwr(area.fi)["healthcare"][${names}];);out center tags;`)).elements;
for (const element of osm) {
  const tags = element.tags, name = tags.name ?? "";
  if ((tags.amenity === "hospital" || tags.healthcare === "hospital") && !/terveyskeskus|hälsocentral|hälsostation|sote|terveysasema|sosiaali- ja terveys/i.test(name)) continue;
  if (NOT_PUBLIC.test(`${name} ${tags.operator ?? ""}`) || !STATION.test(name) || SUB_UNIT.test(name.split(",")[0])) continue;
  const at = [element.lon ?? element.center.lon, element.lat ?? element.center.lat];
  const muni = nearestMuni(at);
  if (ALAND.has(municipalities[muni].code)) continue;
  addStation({ name, at, muni, hours: null, source: "osm" });
}
if (stations.length < 350) throw new Error(`Only ${stations.length} health stations`);

// ---- Candidate mobile-clinic stops: villages and towns more than 8 km from a health station -------------
const places = (await overpass('node(area.fi)["place"~"^(town|village)$"]["name"];out;')).elements;
const stops = [];
for (const place of places) {
  const at = [place.lon, place.lat];
  if (stations.some(station => metres(at, station.at) < 8000)) continue;
  const nearby = cells.reduce((sum, cell) => metres(at, cell) < 10_000 ? sum + cell[2] : sum, 0);
  if (nearby < 250) continue;
  stops.push({ name: place.tags["name:fi"] ?? place.tags.name, at, nearby });
}
stops.sort((a, b) => b.nearby - a.nearby);
const keptStops = [];
for (const stop of stops) if (keptStops.every(other => metres(stop.at, other.at) > 6000)) keptStops.push(stop);

const snapshot = {
  generated_at: new Date().toISOString(),
  region: "Mainland Finland",
  sources: [
    { id: "grid", title: "Population grid 1 km, 31.12.2024 (residents and aged 65+)", publisher: "Statistics Finland", licence: "CC BY 4.0", url: "https://www.stat.fi/org/avoindata/paikkatietoaineistot/vaestoruutuaineisto_1km_en.html" },
    { id: "language", title: `Population by mother tongue and municipality, ${year} (StatFin 11rm)`, publisher: "Statistics Finland", licence: "CC BY 4.0", url: "https://pxdata.stat.fi/PxWeb/pxweb/fi/StatFin/StatFin__vaerak/statfin_vaerak_pxt_11rm.px/" },
    { id: "visits", title: "GP visits in primary care per 1,000 residents (4123); non-urgent GP visits waiting over 7 days (6411)", publisher: "THL Sotkanet", licence: "CC BY 4.0", url: "https://sotkanet.fi/" },
    { id: "stations", title: "Health stations and opening hours", publisher: "Suomi.fi Service Catalogue (DVV)", licence: "CC BY 4.0", url: "https://www.suomi.fi/" },
    { id: "osm", title: "Health stations missing from the catalogue; villages and towns", publisher: "OpenStreetMap contributors", licence: "ODbL 1.0", url: "https://www.openstreetmap.org/copyright" },
  ],
  cell_km: CELL_M / 1000,
  counties: countyList,
  municipalities: municipalities.map(({ code: muniCode, ...rest }) => ({ code: muniCode, ...rest })),
  // [longitude, latitude, residents, residents aged 65+, municipality index]
  cells,
  stations: stations.map((station, id) => ({ id, name: station.name, lon: round(station.at[0], 4), lat: round(station.at[1], 4), muni: station.muni, hours: station.hours, source: station.source })),
  stops: keptStops.map((stop, id) => ({ id, name: stop.name, lon: round(stop.at[0], 4), lat: round(stop.at[1], 4) })),
};
writeFileSync(out, `${JSON.stringify(snapshot)}\n`);
console.log(`Wrote ${cells.length} squares (${cells.reduce((s, c) => s + c[2], 0)} residents), ${municipalities.length} municipalities, ${countyList.length} counties, ${stations.length} stations (${fromCatalogue} from the catalogue), ${keptStops.length} stops`);
