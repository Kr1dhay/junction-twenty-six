import test from "node:test";
import assert from "node:assert/strict";
import { weeklyHours } from "../twin-hours.mjs";

test("opening hours split weekday 8–16 from evening, early and Saturday hours", () => {
  // Published text for Kannelmäki and Ruoholahti health stations (Helsinki Service Map).
  const kannelmaki = "Voimassa toistaiseksi:\n– ma-ke\n     7.00-8.00 ajanvarauksella\n     8.00-16.00\n     16.00-20.00 ajanvarauksella\n– to\n     7.00-8.00 ajanvarauksella\n     8.00-16.00\n     16.00-18.00 ajanvarauksella\n– pe\n     7.00-8.00 ajanvarauksella\n     8.00-16.00\n– la-su suljettu";
  assert.deepEqual(weeklyHours(kannelmaki), { day: 40, extended: 19 });
  assert.deepEqual(weeklyHours("Voimassa toistaiseksi:\n– ma-pe\n 8.00-16.00\n– la 9.00-15.00 ajanvarauksella\n– su suljettu"), { day: 40, extended: 6 });
  assert.deepEqual(weeklyHours("Voimassa toistaiseksi:\n– ma-ti, to-pe 8.00-16.00\n– ke 8.00-18.00\n– la-su suljettu"), { day: 40, extended: 2 });
  assert.deepEqual(weeklyHours(""), { day: 0, extended: 0 });
});
