import test from "node:test";
import assert from "node:assert/strict";
import snapshot from "../src/lib/twin-snapshot.json";
import { applyResource, carMinutes, closureImpact, decay, defaultSettings, gains, noCarMinutes, prepare, runSimulation, summary, week, type TwinData } from "../src/lib/twin";

const data = snapshot as unknown as TwinData;
const p = prepare(data);
const base = week(p, defaultSettings);

test("travel estimates: rural driving is faster per km, buses wait longer in the countryside", () => {
  assert.equal(decay(0), 1);
  assert.equal(decay(30), 0);
  assert.ok(carMinutes(10, 0) > carMinutes(10, 2));
  assert.ok(noCarMinutes(10, 2) > noCarMinutes(10, 0));
  assert.ok(noCarMinutes(10, 1, 1, true) > noCarMinutes(10, 1));
});

test("station capacity reproduces the published national GP visit volume", () => {
  const visits = p.capacity.reduce((sum, value) => sum + value, 0);
  const published = data.cells.reduce((sum, cell) => sum + cell[2] * data.municipalities[cell[4]]!.gp_visits_per_1000 / 1000, 0);
  assert.ok(Math.abs(visits - published) / published < 1e-9);
  assert.ok(Math.abs(base.target - p.national) < 1e-6);
});

test("disruptions make care harder to reach", () => {
  const now = summary(p, base);
  assert.ok(summary(p, week(p, { ...defaultSettings, storm: true })).farByCar > now.farByCar);
  assert.ok(summary(p, week(p, { ...defaultSettings, busStrike: true })).far65NoCar > now.far65NoCar);
  const j = data.stations.findIndex(station => /Kontula/.test(station.name));
  const closed = week(p, { ...defaultSettings, closed: [data.stations[j]!.id] });
  const impact = closureImpact(p, base, closed, j);
  assert.ok(impact.moved > 1000 && impact.lostVisits > 0 && impact.to.length > 0);
  assert.ok(impact.to.every(destination => destination.station !== j));
});

test("each resource's gain matches what the map shows after placing it", () => {
  for (const resource of ["gp", "interpreter", "clinic"] as const) {
    const g = gains(p, base, defaultSettings, resource);
    const best = g.indexOf(Math.max(...g));
    assert.ok(g[best]! > 0, resource);
    const placed = applyResource(p, defaultSettings, base, resource, best);
    assert.ok(placed.helped.length > 0, resource);
    if (resource === "clinic") assert.ok(Math.abs(placed.helped.reduce((sum, h) => sum + h.amount, 0) - g[best]!) < 1e-6);
    if (resource === "gp") assert.ok(placed.recipientsAccess < base.target);
  }
});

test("simulations are seeded and repeatable", () => {
  const one = runSimulation(p, defaultSettings, "interpreter", 3, 7), two = runSimulation(p, defaultSettings, "interpreter", 3, 7);
  assert.deepEqual(Array.from(one.mean), Array.from(two.mean));
  assert.equal(one.scenarios, 3 * data.stations.length);
  assert.notDeepEqual(Array.from(runSimulation(p, defaultSettings, "interpreter", 3, 8).mean), Array.from(one.mean));
});

test("the snapshot holds only published aggregates and public places", () => {
  assert.deepEqual(Object.keys(data).sort(), ["cell_km", "cells", "counties", "generated_at", "municipalities", "region", "sources", "stations", "stops"]);
  for (const cell of data.cells) assert.equal(cell.length, 5);
  assert.deepEqual(Object.keys(data.municipalities[0]!).sort(), ["code", "county", "foreign_language", "gp_visits_per_1000", "name", "wait_over_7_days"]);
  const text = JSON.stringify(data).toLowerCase();
  for (const word of ["patient", "referral", "nationality", "citizenship", "kansalai", "immigra", "asylum"]) assert.ok(!text.includes(word), word);
  assert.ok(data.cells.reduce((sum, cell) => sum + cell[2], 0) > 5_000_000);
});
