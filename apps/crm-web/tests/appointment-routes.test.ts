import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { demoReferrals } from "@edgecare/shared-types/fixtures";
import { GET as slots } from "../src/app/appointments/slots/route";
import { GET, POST, DELETE } from "../src/app/referrals/[id]/appointment/route";
import { backend } from "../src/server/backend";
import { createSession } from "../src/server/auth";

test("appointment routes enforce issuer writes, clinician reads, same-origin, strict bodies and conflict responses", async () => {
  Object.assign(process.env, { DEMO_MODE: "true", CHAIN: "mock", LLM: "ondevice", DATABASE_URL: "", VERCEL: "",
    EDGECARE_DB_PATH: ":memory:", EDGECARE_PUBLIC_ORIGIN: "https://unit.test", EDGECARE_ISSUER_TOKEN: "booking-issuer", EDGECARE_CLINICIAN_TOKEN: "booking-clinician" });
  const id = randomUUID(), ctx = { params: Promise.resolve({ id }) };
  await backend().create({ ...demoReferrals[0]!, referral_id: id, expires_at: "2031-01-01T00:00:00Z" });
  const req = (method: string, body?: unknown, token = "booking-issuer", origin?: string) => new Request(`https://unit.test/referrals/${id}/appointment`, {
    method, headers: { authorization: `Bearer ${token}`, ...(origin ? { origin } : {}) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  assert.equal((await GET(req("GET", undefined, "wrong"), ctx)).status, 401);
  assert.equal((await GET(req("GET", undefined, "booking-clinician", "https://evil.test"), ctx)).status, 403);
  assert.equal((await GET(req("GET", undefined, "booking-clinician"), ctx)).status, 200);
  assert.equal((await GET(new Request(`https://unit.test/referrals/${id}/appointment`, { headers: { cookie: `edgecare_demo_session=${createSession()}` } }), ctx)).status, 200);
  const available = await (await slots(req("GET"))).json();
  const body = { slot_id: available.slots[0].slot_id, operation_id: randomUUID() };
  assert.equal((await POST(req("POST", body, "booking-clinician"), ctx)).status, 401);
  assert.equal((await POST(req("POST", { ...body, passcode: "1234" }), ctx)).status, 400);
  assert.equal((await POST(req("POST", { slot_id: "x".repeat(2000), operation_id: randomUUID() }), ctx)).status, 400);
  const booked = await POST(req("POST", body), ctx);
  assert.equal(booked.status, 200);
  assert.equal(booked.headers.get("cache-control"), "no-store");
  assert.equal((await booked.json()).appointment.demo, true);
  assert.equal((await POST(req("POST", body), ctx)).status, 200);
  assert.equal((await POST(req("POST", { slot_id: available.slots[1].slot_id, operation_id: randomUUID() }), ctx)).status, 409);
  assert.equal((await GET(req("GET"), { params: Promise.resolve({ id: randomUUID() }) })).status, 404);
  assert.equal((await GET(req("GET"), { params: Promise.resolve({ id: "bad" }) })).status, 400);
  assert.equal((await DELETE(req("DELETE", { appointment_id: body.operation_id }, "booking-clinician"), ctx)).status, 401);
  assert.equal((await DELETE(req("DELETE", { appointment_id: body.operation_id }), ctx)).status, 200);
  assert.equal((await GET(req("GET"), ctx)).status, 200);
  assert.equal((await (await GET(req("GET"), ctx)).json()).appointment, null);
  assert.equal((await DELETE(req("DELETE", { appointment_id: body.operation_id }), ctx)).status, 200);
});
