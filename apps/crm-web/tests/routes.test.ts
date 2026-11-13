import test from "node:test";
import assert from "node:assert/strict";
import { GET, POST } from "../src/app/referrals/route";
import { GET as detail } from "../src/app/referrals/[id]/route";
import { GET as verification } from "../src/app/referrals/[id]/verification/route";
import { demoReferrals } from "@edgecare/shared-types/fixtures";

test("routes validate enrollment and expose only the correct read model", async () => {
  process.env.DEMO_MODE = "true"; process.env.CHAIN = "mock"; process.env.LLM = "ondevice";
  process.env.EDGECARE_DB_PATH = ":memory:";
  const record = { ...demoReferrals[0]!, referral_id: "11111111-1111-4111-8111-111111111111" };
  const post = (body: unknown) => POST(new Request("http://localhost/referrals", { method: "POST", body: JSON.stringify(body) }));
  assert.equal((await post(record)).status, 201);
  assert.equal((await post(record)).status, 200);
  assert.equal((await post({ ...record, language: "fi" })).status, 409);
  assert.equal((await post({ ...record, status: "spent" })).status, 400);
  assert.equal((await post({ ...record, patient_name: "Forbidden" })).status, 400);
  const list = await GET();
  assert.equal(list.headers.get("Cache-Control"), "no-store");
  const payload = await list.json();
  assert.ok(payload.referrals.every((item: object) => !("salt" in item) && !("signature_template_encrypted" in item)));
  const context = { params: Promise.resolve({ id: record.referral_id }) };
  const envelope = await verification(new Request("http://localhost"), context);
  assert.equal((await envelope.json()).signature_template_encrypted, record.signature_template_encrypted);
  assert.equal((await detail(new Request("http://localhost"), { params: Promise.resolve({ id: "missing" }) })).status, 404);
  process.env.DEMO_MODE = "false";
  assert.equal((await GET()).status, 503);
  assert.equal((await post(record)).status, 503);
});
