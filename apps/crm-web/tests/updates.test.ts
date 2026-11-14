import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { demoReferrals } from "@edgecare/shared-types/fixtures";
import { DemoRepository, ConflictError } from "../src/server/repository";
import { PATCH, GET } from "../src/app/referrals/[id]/route";
import { POST } from "../src/app/referrals/route";

test("updating clinical details retains identity and consumed status, supports exact retry and rejects stale writes", () => {
  const directory = mkdtempSync(join(tmpdir(), "edgecare-update-"));
  const path = join(directory, "db.sqlite");
  const a = new DemoRepository(path), b = new DemoRepository(path);
  const original = { ...demoReferrals[0]!, referral_id: randomUUID() };
  try {
    a.create(original); a.create(original.referral_id, original.commitment_hash);
    a.spend(original.referral_id, original.commitment_hash, randomUUID());
    const account = a.read(original.referral_id);
    const updated = { ...original, free_text_summary: "Updated English profile", triage_detail_encrypted: Buffer.from("new synthetic encrypted clinical details, no plain PIN").toString("base64") };
    a.update(original, updated);
    b.update(original, updated);
    assert.deepEqual(b.verificationEnvelope(original.referral_id), updated);
    assert.deepEqual(b.read(original.referral_id), account);
    assert.equal(b.get(original.referral_id)?.status, "spent");
    assert.equal(b.list().length, 1);
    assert.throws(() => b.update(original, { ...original, free_text_summary: "Stale competing change" }), ConflictError);
    for (const field of ["referral_id", "created_at", "source", "kiosk_id", "signature_template_encrypted", "salt", "commitment_hash", "status", "expires_at"] as const) {
      const changed = { ...updated, [field]: field === "status" ? "spent" : "changed" };
      assert.throws(() => a.update(updated, changed as typeof updated), ConflictError, field);
    }
  } finally { a.close(); b.close(); rmSync(directory, { recursive: true, force: true }); }
});

test("update route requires an issuer token, validates the whole replacement and protects concurrent changes", async () => {
  const directory = mkdtempSync(join(tmpdir(), "edgecare-update-route-"));
  process.env.DEMO_MODE = "true"; process.env.CHAIN = "mock"; process.env.LLM = "ondevice";
  process.env.EDGECARE_DB_PATH = join(directory, "db.sqlite");
  process.env.EDGECARE_ISSUER_TOKEN = "update-test-issuer";
  process.env.EDGECARE_CLINICIAN_TOKEN = "update-test-clinician";
  const original = { ...demoReferrals[0]!, referral_id: randomUUID() };
  const updated = { ...original, free_text_summary: "Corrected English clinical profile" };
  const context = { params: Promise.resolve({ id: original.referral_id }) };
  const request = (body: unknown, token = "update-test-issuer", method = "PATCH") => new Request("http://localhost/referrals/" + original.referral_id, {
    method, headers: { "Content-Type": "application/json", ...(token ? { Authorization: "Bearer " + token } : {}) },
    ...(method === "GET" ? {} : { body: JSON.stringify(body) }),
  });
  try {
    assert.equal((await POST(request(original, undefined, "POST"))).status, 201);
    assert.equal((await PATCH(request({ expected: original, record: updated }, ""), context)).status, 401);
    assert.equal((await PATCH(request({ expected: original, record: updated }, "update-test-clinician"), context)).status, 401);
    assert.equal((await PATCH(request({ expected: original, record: updated, passcode: "1234" }), context)).status, 400);
    assert.equal((await PATCH(request({ expected: original, record: { ...updated, commitment_hash: "a".repeat(64) } }), context)).status, 409);
    assert.equal((await PATCH(request({ expected: original, record: updated }), context)).status, 200);
    assert.equal((await PATCH(request({ expected: original, record: updated }), context)).status, 200);
    assert.equal((await PATCH(request({ expected: original, record: { ...updated, free_text_summary: "Competing stale change" } }), context)).status, 409);
    const crm = await (await GET(request(undefined, "update-test-clinician", "GET"), context)).json();
    assert.equal(crm.free_text_summary, updated.free_text_summary);
    assert.equal("triage_detail_encrypted" in crm, false);
    const missing = { ...original, referral_id: randomUUID() };
    assert.equal((await PATCH(request({ expected: missing, record: missing }), { params: Promise.resolve({ id: missing.referral_id }) })).status, 404);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
