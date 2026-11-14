import test from "node:test";
import assert from "node:assert/strict";
import { access, baselineSupply, buildWeights, candidateGain, decay, defaultAssumptions, demand, expectedWeek, librarySite, minutes,
  noDisruptions, runScenarios, shortfall, stationSite, total, twinData, type TwinData } from "../src/lib/twin";

const a = defaultAssumptions;

test("travel decay runs from 1 at the door to 0 at the catchment edge", () => {
  assert.equal(decay(0), 1);
  assert.equal(decay(40), 0);
  assert.ok(decay(10) > decay(20) && decay(20) > decay(30));
  // Step-free walking is slower; a strike removes the transit option.
  assert.ok(minutes(2, true, false) > minutes(2, false, false));
  assert.ok(minutes(6, false, false) > minutes(6, false, true));
});

test("E2SFCA shares a station's capacity among everyone who can reach it", () => {
  const tiny: TwinData = { ...twinData, areas: [{ id: 1, name: "A", population: 300, foreign_language: 0.5, aged_75: 0.1 }],
    cells: [[24.94, 60.17, 100, 0], [24.95, 60.17, 200, 0]],
    stations: [{ ...twinData.stations[0]!, lon: 24.94, lat: 60.17, hours: { day: 40, extended: 10 }, wheelchair_shortcomings: 0 }], libraries: [] };
  const sites = tiny.stations.map(stationSite);
  const w = buildWeights(tiny, sites, true);
  const people = demand(tiny, a);
  const supply = baselineSupply(tiny, a, noDisruptions);
  const result = access(tiny, sites, w, people, supply, a);
  const reach = 100 * w.normal[0]! + 200 * w.normal[1]!;
  assert.ok(Math.abs(result.ratio[0]! - supply.capacity[0]! / reach) < 1e-9);
  assert.ok(Math.abs(result.everyone[0]! - result.ratio[0]! * w.normal[0]!) < 1e-9);
  // Remote interpreting covers half of language needs, so that group reaches half the capacity.
  assert.ok(Math.abs(result.language[0]! - result.everyone[0]! * a.remoteInterpreting) < 1e-9);
});

test("the fast candidate gain equals a full recompute of the city", () => {
  const stations = twinData.stations.map(stationSite), libraries = twinData.libraries.map(librarySite), sites = [...stations, ...libraries];
  const w = buildWeights(twinData, sites, true);
  const people = demand(twinData, a);
  const supply = baselineSupply(twinData, a, noDisruptions, libraries.length);
  libraries.forEach((_, k) => { supply.interpreting[stations.length + k] = a.remoteInterpreting; });
  const before = access(twinData, sites, w, people, supply, a);
  for (const [resource, site] of [["clinician", stations[3]!], ["interpreter", stations[7]!], ["vehicle", libraries[5]!]] as const) {
    const j = sites.indexOf(site);
    const week = expectedWeek(a, noDisruptions, { resource, site });
    const full = total(week.shortfallBefore) - total(week.shortfallAfter!);
    const fast = candidateGain(people, before, sites, w, supply, a, resource, j);
    assert.ok(full > 0, `${resource} should help`);
    assert.ok(Math.abs(fast - full) / full < 1e-6, `${resource}: fast ${fast} vs full ${full}`);
  }
});

test("disruptions make access worse", () => {
  const base = total(expectedWeek(a, noDisruptions).shortfallBefore);
  assert.ok(total(expectedWeek(a, { ...noDisruptions, transitStrike: true }).shortfallBefore) > base);
  const noInterpreting = expectedWeek(a, { ...noDisruptions, remoteInterpretingDown: true }).shortfallBefore;
  assert.ok(noInterpreting.language > expectedWeek(a, noDisruptions).shortfallBefore.language);
  const busiest = expectedWeek(a, noDisruptions);
  const closed = expectedWeek(a, { ...noDisruptions, closed: [twinData.stations[0]!.id] });
  assert.ok(total(shortfall(closed.people, closed.before, busiest.target)) > total(busiest.shortfallBefore));
});

test("scenario runs are seeded and repeatable", async () => {
  const options = { draws: 4, assumptions: a, disruptions: noDisruptions };
  const one = await runScenarios({ ...options, seed: 7 }), two = await runScenarios({ ...options, seed: 7 });
  assert.deepEqual(one, two);
  assert.equal(one.scenarios, 4 * (twinData.stations.length * 2 + twinData.libraries.length + 1));
  const other = await runScenarios({ ...options, seed: 8 });
  assert.notEqual(other.baselineShortfall, one.baselineShortfall);
  for (const list of Object.values(one.byResource)) for (let k = 1; k < list.length; k++) assert.ok(list[k - 1]!.meanGain >= list[k]!.meanGain);
});

test("the snapshot holds only published area-level aggregates", () => {
  assert.deepEqual(Object.keys(twinData).sort(), ["areas", "cell_size_m", "cells", "generated_at", "libraries", "region", "sources", "stations"]);
  for (const area of twinData.areas) assert.deepEqual(Object.keys(area).sort(), ["aged_75", "foreign_language", "id", "name", "population"]);
  for (const cell of twinData.cells) assert.equal(cell.length, 4);
  const station = Object.keys(twinData.stations[0]!).sort();
  assert.deepEqual(station, ["full_name", "hours", "id", "lat", "lon", "name", "url", "wheelchair_shortcomings"]);
  const text = JSON.stringify(twinData).toLowerCase();
  for (const word of ["patient", "referral", "nationality", "citizenship", "immigra", "asylum"]) assert.ok(!text.includes(word), word);
  assert.ok(twinData.sources.every(source => source.licence === "CC BY 4.0"));
});
