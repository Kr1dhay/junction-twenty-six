import test from "node:test";
import assert from "node:assert/strict";
import { actionsFor, briefText, buildBrief, evidence, plans } from "../src/lib/equity-actions";
import { buildPathway, invitationRound, pathwayIndicatorIDs, pointsBehind, projectedParticipation, rankCounties, snapshot, stages, type PathwayData } from "../src/lib/pathway";
import { byLongestWaiting, formatWait, overdue, waitingSummary, waitMs } from "../src/lib/waiting";
import { explainBrief } from "../src/server/equity-explanation";
import { loadPathwayData, resetPathwayCache } from "../src/server/pathway-data";
import { POST } from "../src/app/demo/equity/explain/route";
import { GET } from "../src/app/demo/equity/data/route";
import { createSession } from "../src/server/auth";

const region = (id: number, name: string, population = 200_000) => ({ id, code: String(id), name, full_name: name, population });
const indicator = (id: number, national: number, values: Record<string, number | null>, year = 2024) => ({
  id, title: `Indicator ${id}`, organization: "Test registry", updated: "2026-01-01", year, national: { value: national },
  values: Object.fromEntries(Object.entries(values).map(([key, value]) => [key, value === null ? null : { value }])),
});
// Synthetic counties: Alpha trails at screening, Beta at survival, Gamma nowhere, Delta has no screening figure.
const fixture: PathwayData = {
  generated_at: "2026-11-14T00:00:00.000Z", source: "Test", source_url: "https://example.test/", national_region_id: 9, population_year: 2025,
  regions: [region(1, "Alpha"), region(2, "Beta", 50_000), region(3, "Gamma"), region(4, "Delta")],
  indicators: {
    3621: { ...indicator(3621, 80, { 1: 70, 2: 84, 3: 84, 4: null }), national: { value: 80, count: 8000 },
      values: { 1: { value: 70, count: 700 }, 2: { value: 84, count: 840 }, 3: { value: 84, count: 840 }, 4: null } },
    6411: indicator(6411, 50, { 1: 50.5, 2: 40, 3: 45, 4: 60 }, 2025),
    3627: indicator(3627, 68, { 1: 70, 2: 62, 3: 68, 4: 69 }),
  },
};
const env = (values: Record<string, string | undefined>) => {
  const before = Object.fromEntries(Object.keys(values).map(key => [key, process.env[key]]));
  for (const [key, value] of Object.entries(values)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
  return () => { for (const [key, value] of Object.entries(before)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; } };
};
const demo = { DEMO_MODE: "true", CHAIN: "mock", LLM: "ondevice" };

test("gaps are percentage points behind Finland in either direction, and ranks share ties", () => {
  assert.equal(pointsBehind(74.3, 81.6, "higher"), 7.3);
  assert.equal(pointsBehind(75.9, 54.7, "lower"), 21.2);
  assert.equal(pointsBehind(84, 80, "higher"), -4);
  const ranking = rankCounties(fixture, 3621);
  assert.deepEqual(ranking.map(row => [row.region.name, row.rank, row.gap]), [["Beta", 1, -4], ["Gamma", 1, -4], ["Alpha", 3, 10], ["Delta", null, null]]);
  assert.deepEqual(rankCounties(fixture, 6411).map(row => row.region.name), ["Beta", "Gamma", "Alpha", "Delta"]);
  assert.deepEqual(rankCounties(fixture, 999), []);
});

test("a stage is flagged only from one point behind, and the weakest rank is furthest behind", () => {
  const alpha = buildPathway(fixture, 1)!;
  assert.equal(alpha.furthest, "screening");
  // 0.5 points behind on GP waits is below the flag threshold.
  assert.deepEqual(alpha.stages.map(stage => [stage.id, stage.behind]), [["screening", true], ["access", false], ["barriers", false], ["referral", false], ["outcomes", false]]);
  assert.equal(alpha.stages[2]!.worst, null);
  const beta = buildPathway(fixture, 2)!;
  assert.equal(beta.furthest, "outcomes");
  assert.equal(beta.smallPopulation, true);
  assert.equal(beta.stages[4]!.worst!.rank, 4);
  assert.equal(buildPathway(fixture, 3)!.furthest, null);
  const delta = buildPathway(fixture, 4)!;
  assert.equal(delta.stages[0]!.worst, null);
  assert.equal(delta.furthest, "access");
  assert.equal(buildPathway(fixture, 99), undefined);
});

test("plans follow the flagged stages and stay transparent about owner, evidence and limits", () => {
  const actions = actionsFor(buildPathway(fixture, 1)!);
  assert.deepEqual(actions.map(action => action.id), ["screening"]);
  assert.equal(actions[0]!.gap, 10);
  assert.deepEqual(actionsFor(buildPathway(fixture, 3)!), []);
  for (const stage of stages) {
    const plan = plans[stage.id];
    assert.ok(plan.owner && plan.resources && plan.steps.length && plan.measure && plan.target);
    assert.ok(evidence[plan.source].url.startsWith("https://") && evidence[plan.source].limitation);
  }
});

test("the brief states the figures it was given and nothing is flagged without a gap", () => {
  const brief = buildBrief(buildPathway(fixture, 1)!);
  assert.match(brief.gap, /Alpha is furthest behind on breast screening participation: 70% against 80% for Finland in 2024/);
  assert.match(brief.gap, /10 percentage points worse, ranking 3 of 3 counties/);
  assert.match(brief.where, /stage 1 of 5, screening/);
  assert.match(brief.where, /level with or ahead of Finland on survival/);
  assert.match(brief.action, /Multilingual invitations \+ navigator outreach, owned by the regional screening coordinator/);
  assert.equal(brief.evidence, "navigation");
  const none = buildBrief(buildPathway(fixture, 3)!);
  assert.equal(none.evidence, null);
  assert.match(briefText(none), /No action is triggered/);
});

test("target arithmetic uses published counts and never forecasts an effect", () => {
  const round = invitationRound({ value: 70, count: 700 })!;
  assert.deepEqual(round, { invited: 1000, attended: 700, needed: 100 });
  assert.deepEqual(projectedParticipation(round, 0), { extra: 0, rate: 70 });
  assert.deepEqual(projectedParticipation(round, 1 / 3), { extra: 100, rate: 80 });
  assert.deepEqual(projectedParticipation(round, 5), { extra: 300, rate: 100 });
  assert.equal(invitationRound({ value: 84, count: 840 })!.needed, 0);
  for (const cell of [null, undefined, { value: 70 }, { value: 0, count: 5 }, { value: 120, count: 5 }]) assert.equal(invitationRound(cell), null);
});

test("the committed snapshot covers every pathway measure and briefs every county", () => {
  assert.ok(snapshot.regions.length >= 20);
  for (const id of pathwayIndicatorIDs) {
    const data = snapshot.indicators[id]!;
    assert.ok(data.national.value > 0 && data.year >= 2023 && data.organization, `indicator ${id}`);
    assert.ok(Object.values(data.values).filter(Boolean).length >= 15, `indicator ${id} counties`);
  }
  for (const county of snapshot.regions) {
    const pathway = buildPathway(snapshot, county.id)!;
    assert.equal(pathway.stages.length, 5);
    assert.ok(briefText(buildBrief(pathway)).length > 100);
    assert.equal(actionsFor(pathway)[0]?.id, pathway.furthest ?? undefined);
  }
  assert.ok(!JSON.stringify(snapshot).includes("referral_id"));
});

test("AI explains only the supplied brief and rejects invented citations and numbers", async () => {
  const restore = env({ RUNWARE_API_KEY: "test-key", RUNWARE_MODEL: "google:gemini@3-flash" });
  const reply = (explanation: string, evidence_ids = ["navigation"]) => Response.json({ choices: [{ message: { tool_calls: [{ function: {
    name: "explain_brief", arguments: JSON.stringify({ explanation, evidence_ids }) } }] } }] });
  const alpha = buildPathway(fixture, 1)!;
  try {
    const result = await explainBrief(alpha, async (_url, init) => {
      const body = JSON.parse(String(init!.body));
      const context = JSON.parse(body.messages[1].content);
      assert.equal(context.retrieved_evidence.id, "navigation");
      assert.equal(context.stage.measures[0].points_behind_finland, 10);
      assert.ok(!String(init!.body).includes("referral_id"));
      return reply("Alpha is at 70% against 80% for Finland. Navigation can address practical barriers; the evidence is largely from the US.");
    });
    assert.deepEqual(result.evidence_ids, ["navigation"]);
    await assert.rejects(explainBrief(buildPathway(fixture, 3)!, async () => reply("None")), /No gap/);
    await assert.rejects(explainBrief(alpha, async () => reply("Claim", ["diagnosis"])), /Unsupported citation/);
    await assert.rejects(explainBrief(alpha, async () => reply("Navigation would raise participation by 15 points.")), /Unsupported number/);
    await assert.rejects(explainBrief(alpha, async () => new Response("", { status: 502 })), /Runware returned HTTP 502/);
    await assert.rejects(explainBrief(alpha, async () => Response.json({ choices: [] })));
  } finally { restore(); }
});

test("equity routes reject unauthenticated and cross-origin requests", async () => {
  const restore = env(demo);
  try {
    const crossOrigin = { headers: { origin: "https://untrusted.example" } };
    assert.equal((await POST(new Request("https://example.com/demo/equity/explain", { method: "POST", body: "{}", ...crossOrigin }))).status, 403);
    assert.equal((await POST(new Request("https://example.com/demo/equity/explain", { method: "POST", body: "{}" }))).status, 401);
    assert.equal((await GET(new Request("https://example.com/demo/equity/data", crossOrigin))).status, 403);
    assert.equal((await GET(new Request("https://example.com/demo/equity/data"))).status, 401);
  } finally { restore(); }
});

test("browser session reads public data; malformed input and a missing provider fail safely", async () => {
  const restore = env({ ...demo, RUNWARE_API_KEY: undefined, RUNWARE_MODEL: undefined, EDGECARE_PUBLIC_DATA: "snapshot" });
  const cookie = `edgecare_demo_session=${createSession()}`;
  const request = (body: unknown) => new Request("https://example.com/demo/equity/explain", { method: "POST",
    headers: { cookie, "content-type": "application/json" }, body: JSON.stringify(body) });
  const county = snapshot.regions.find(item => buildPathway(snapshot, item.id)!.furthest)!;
  try {
    const data = await GET(new Request("https://example.com/demo/equity/data", { headers: { cookie } }));
    assert.equal(data.status, 200);
    const body = await data.json() as PathwayData;
    assert.equal(body.live, false);
    assert.equal(body.regions.length, snapshot.regions.length);
    assert.equal((await POST(request({ region: 1, basis: "snapshot" }))).status, 400);
    assert.equal((await POST(request({ region: county.id }))).status, 400);
    assert.equal((await POST(request({ region: county.id, basis: "snapshot", patient: "must not be accepted" }))).status, 400);
    assert.equal((await POST(request({ region: county.id, basis: "live" }))).status, 503);
    const response = await POST(request({ region: county.id, basis: "snapshot" }));
    assert.equal(response.status, 503);
    assert.match((await response.json()).error, /data-based brief remains available/);
  } finally { restore(); }
});

test("live refresh replaces snapshot figures, and any failure falls back to the snapshot", async () => {
  const restore = env({ EDGECARE_PUBLIC_DATA: undefined });
  const now = Date.parse("2026-11-14T12:00:00.000Z");
  const county = snapshot.regions[0]!.id;
  let calls = 0;
  const live: typeof fetch = async url => {
    calls++;
    const id = Number(new URL(String(url)).searchParams.get("indicator"));
    const known = snapshot.indicators[id]!;
    assert.ok(String(url).startsWith("https://sotkanet.fi/rest/1.1/json?") && String(url).includes(`years=${known.year}`));
    const row = (regionID: number, value: number) => ({ indicator: id, region: regionID, year: known.year, gender: "total", value, absValue: 10 });
    return Response.json([row(snapshot.national_region_id, 55.5), ...snapshot.regions.map(item => row(item.id, 44.4)),
      { ...row(county, 1), gender: "female" }, { ...row(county, 2), year: known.year - 1 }, row(123456, 3)]);
  };
  try {
    resetPathwayCache();
    const fresh = await loadPathwayData(live, now);
    assert.equal(fresh.live, true);
    assert.equal(fresh.generated_at, "2026-11-14T12:00:00.000Z");
    assert.deepEqual(fresh.indicators[3621]!.values[county], { value: 44.4, count: 10 });
    assert.equal(fresh.indicators[3621]!.national.value, 55.5);
    assert.equal(calls, pathwayIndicatorIDs.length);
    await loadPathwayData(live, now + 60_000);
    assert.equal(calls, pathwayIndicatorIDs.length, "fresh data is cached");
    for (const failing of [
      async () => new Response("", { status: 500 }),
      async () => Response.json([{ region: snapshot.national_region_id, year: 2024, gender: "total", value: 50 }]),
      async () => Response.json({ unexpected: true }),
      async () => { throw new Error("offline"); },
    ] as (typeof fetch)[]) {
      resetPathwayCache();
      const fallback = await loadPathwayData(failing, now);
      assert.equal(fallback.live, false);
      assert.deepEqual(fallback.indicators, snapshot.indicators);
    }
    process.env.EDGECARE_PUBLIC_DATA = "snapshot";
    resetPathwayCache();
    assert.equal((await loadPathwayData(async () => { throw new Error("must not be called"); }, now)).live, false);
  } finally { resetPathwayCache(); restore(); }
});

test("waiting clocks measure receipt to now or to verification, and flag long open waits", () => {
  const now = Date.parse("2026-11-14T12:00:00.000Z");
  const record = (created_at: string, status: "open" | "spent" | "expired", spentAt?: string) => ({ created_at, status,
    status_history: [{ status: "open" as const, at: created_at }, ...(spentAt ? [{ status: "spent" as const, at: spentAt }] : [])] });
  const fresh = record("2026-11-14T09:00:00.000Z", "open"), old = record("2026-11-05T09:00:00.000Z", "open");
  const seen = record("2026-11-10T09:00:00.000Z", "spent", "2026-11-12T15:00:00.000Z"), expired = record("2026-11-01T09:00:00.000Z", "expired");
  assert.equal(waitMs(fresh, now), 3 * 3_600_000);
  assert.equal(waitMs(seen, now), 54 * 3_600_000);
  assert.equal(waitMs(expired, now), null);
  assert.equal(waitMs(record("2026-11-10T09:00:00.000Z", "spent"), now), null);
  assert.deepEqual([fresh, old, seen, expired].map(item => overdue(item, now)), [false, true, false, false]);
  assert.deepEqual([30_000, 59 * 60_000, 3 * 3_600_000, 54 * 3_600_000, 48 * 3_600_000].map(formatWait), ["1 min", "59 min", "3 h", "2 d 6 h", "2 d"]);
  assert.deepEqual(waitingSummary([fresh, old, seen, expired], now), { open: 2, longestOpen: 219 * 3_600_000, medianOpen: 111 * 3_600_000,
    overdue: 1, verified: 1, medianToVerified: 54 * 3_600_000 });
  assert.deepEqual(waitingSummary([], now), { open: 0, longestOpen: null, medianOpen: null, overdue: 0, verified: 0, medianToVerified: null });
  assert.deepEqual([seen, fresh, expired, old].sort(byLongestWaiting), [old, fresh, seen, expired]);
});
