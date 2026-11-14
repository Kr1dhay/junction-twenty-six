import test from "node:test";
import assert from "node:assert/strict";
import { actionIDs, buildAction, percentagePointGap, rate } from "../src/lib/equity-actions";
import { explainAction } from "../src/server/equity-explanation";
import { POST } from "../src/app/demo/equity/explain/route";
import { createSession } from "../src/server/auth";

test("rates validate denominators and calculate percentage points, not relative percent", () => {
  assert.ok(Math.abs(rate(112, 200)! - 56) < 0.00001);
  for (const counts of [[0, 0], [2, 1], [-1, 5], [1.5, 5], [1, Infinity]] as [number, number][]) assert.equal(rate(...counts), null);
  assert.equal(percentagePointGap([112, 200], [144, 200]), 16);
  assert.equal(percentagePointGap([0, 0], [144, 200]), null);
  assert.equal(percentagePointGap([96, 100], [90, 100]), -6);
});

test("only explicit synthetic gaps trigger plans, and sources/targets remain transparent", () => {
  for (const id of actionIDs) {
    const baseline = buildAction(id, "baseline");
    assert.equal(baseline.detected, true);
    assert.match(baseline.basis, /Synthetic/);
    assert.equal(buildAction(id, "improved").detected, false);
    assert.ok(baseline.owner && baseline.resources && baseline.steps.length);
  }
  assert.equal(buildAction("screening", "baseline").gap, 16);
  assert.equal(buildAction("acknowledgment", "baseline").gap, 22);
  assert.equal(buildAction("attendance", "baseline").gap, 18);
});

test("AI retrieves only the selected evidence and rejects invented citations", async () => {
  const previous = { key: process.env.RUNWARE_API_KEY, model: process.env.RUNWARE_MODEL };
  process.env.RUNWARE_API_KEY = "test-key"; process.env.RUNWARE_MODEL = "google:gemini@3-flash";
  try {
    const fetcher: typeof fetch = async (_url, init) => {
      const body = JSON.parse(String(init!.body));
      const context = JSON.parse(body.messages[1].content);
      assert.equal(context.retrieved_evidence.id, "navigation");
      assert.equal(context.plan.gap, 16);
      assert.ok(!String(init!.body).includes("referral_id"));
      return Response.json({ choices: [{ message: { tool_calls: [{ function: { name: "explain_action",
        arguments: JSON.stringify({ explanation: "Navigation can address practical barriers. Adapt the evidence locally.", evidence_ids: ["navigation"] }) } }] } }] });
    };
    const result = await explainAction("screening", "baseline", fetcher);
    assert.deepEqual(result.evidence_ids, ["navigation"]);
    await assert.rejects(explainAction("screening", "improved", fetcher), /No gap/);
    await assert.rejects(explainAction("screening", "baseline", async () => Response.json({ choices: [{ message: { tool_calls: [{ function: {
      name: "explain_action", arguments: JSON.stringify({ explanation: "Claim", evidence_ids: ["diagnosis"] }),
    } }] } }] })), /Unsupported citation/);
    await assert.rejects(explainAction("screening", "baseline", async () => new Response("", { status: 502 })), /Runware returned HTTP 502/);
    await assert.rejects(explainAction("screening", "baseline", async () => Response.json({ choices: [] })));
  } finally {
    if (previous.key === undefined) delete process.env.RUNWARE_API_KEY; else process.env.RUNWARE_API_KEY = previous.key;
    if (previous.model === undefined) delete process.env.RUNWARE_MODEL; else process.env.RUNWARE_MODEL = previous.model;
  }
});

test("explanation route rejects unauthenticated and cross-origin requests", async () => {
  const keys = ["DEMO_MODE", "CHAIN", "LLM"] as const;
  const before = keys.map(key => process.env[key]);
  process.env.DEMO_MODE = "true"; process.env.CHAIN = "mock"; process.env.LLM = "ondevice";
  try {
    const request = new Request("https://example.com/demo/equity/explain", { method: "POST",
      headers: { origin: "https://untrusted.example" }, body: "{}" });
    assert.equal((await POST(request)).status, 403);
    assert.equal((await POST(new Request("https://example.com/demo/equity/explain", { method: "POST", body: "{}" }))).status, 401);
  } finally { keys.forEach((key, index) => { if (before[index] === undefined) delete process.env[key]; else process.env[key] = before[index]; }); }
});

test("browser session can reach explanation route; malformed input and missing provider fail safely", async () => {
  const keys = ["DEMO_MODE", "CHAIN", "LLM", "RUNWARE_API_KEY", "RUNWARE_MODEL"] as const;
  const before = keys.map(key => process.env[key]);
  process.env.DEMO_MODE = "true"; process.env.CHAIN = "mock"; process.env.LLM = "ondevice";
  delete process.env.RUNWARE_API_KEY; delete process.env.RUNWARE_MODEL;
  const request = (body: unknown) => new Request("https://example.com/demo/equity/explain", { method: "POST",
    headers: { cookie: `edgecare_demo_session=${createSession()}`, "content-type": "application/json" }, body: JSON.stringify(body) });
  try {
    assert.equal((await POST(request({ id: "screening", scenario: "improved" }))).status, 400);
    assert.equal((await POST(request({ id: "screening", scenario: "baseline", patient: "must not be accepted" }))).status, 400);
    const response = await POST(request({ id: "screening", scenario: "baseline" }));
    assert.equal(response.status, 503);
    assert.match((await response.json()).error, /reviewed evidence and action plan remain available/);
  } finally { keys.forEach((key, index) => { if (before[index] === undefined) delete process.env[key]; else process.env[key] = before[index]; }); }
});
