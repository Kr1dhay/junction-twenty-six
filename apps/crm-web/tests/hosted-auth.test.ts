import test from "node:test";
import assert from "node:assert/strict";
import { accessGuard, createSession, isLoopback, sameOrigin, validSession } from "../src/server/auth";
import { POST } from "../src/app/demo/session/route";

test("hosted origins reject spoofed hosts and sessions survive instance-local key changes", () => {
  const keys = ["VERCEL", "EDGECARE_PUBLIC_ORIGIN", "EDGECARE_SESSION_SECRET", "EDGECARE_ISSUER_TOKEN"];
  const previous = Object.fromEntries(keys.map(key => [key, process.env[key]]));
  try {
    process.env.VERCEL = "1";
    process.env.EDGECARE_PUBLIC_ORIGIN = "https://edgecare.example";
    process.env.EDGECARE_SESSION_SECRET = "a".repeat(64);
    process.env.EDGECARE_ISSUER_TOKEN = "private-device-token";
    const request = new Request("http://localhost/demo/voice/turn", { headers: {
      host: "edgecare.example", origin: "https://edgecare.example", authorization: "Bearer private-device-token",
    } });
    assert.equal(sameOrigin(request), true);
    assert.equal(accessGuard(request, "issuer"), undefined);
    assert.equal(isLoopback(new Request("http://localhost/")), false);
    assert.equal(sameOrigin(new Request("http://localhost/", { headers: { host: "localhost", origin: "https://edgecare.example" } })), false);
    assert.equal(sameOrigin(new Request("https://edgecare.example/", { headers: { origin: "https://attacker.example" } })), false);
    const session = createSession();
    (globalThis as typeof globalThis & { edgecareSessionSecret?: string }).edgecareSessionSecret = "new-instance-key";
    assert.equal(validSession(session), true);
    process.env.EDGECARE_SESSION_SECRET = "b".repeat(64);
    assert.equal(validSession(session), false);
    delete process.env.EDGECARE_SESSION_SECRET;
    assert.throws(() => createSession(), /Hosted sessions require/);
  } finally {
    for (const key of keys) { if (previous[key] === undefined) delete process.env[key]; else process.env[key] = previous[key]; }
  }
});

test("CRM opens without a code while retaining origin, demo-mode and device-role guards", async () => {
  const values = {
    VERCEL: "1", EDGECARE_PUBLIC_ORIGIN: "https://edgecare.example",
    EDGECARE_SESSION_SECRET: "c".repeat(64), EDGECARE_CLINICIAN_TOKEN: "clinician-device-only",
    EDGECARE_ISSUER_TOKEN: "issuer-device-only", DEMO_MODE: "true", CHAIN: "mock", LLM: "ondevice",
  };
  const previous = Object.fromEntries(Object.keys(values).map(key => [key, process.env[key]]));
  try {
    Object.assign(process.env, values);
    const response = await POST(new Request("https://edgecare.example/demo/session", {
      method: "POST", headers: { origin: "https://edgecare.example" },
    }));
    assert.equal(response.status, 200);
    const cookie = response.headers.get("set-cookie")!;
    assert.match(cookie, /HttpOnly; SameSite=Strict; Max-Age=28800; Secure/);
    assert.equal(response.headers.get("cache-control"), "no-store");
    const session = cookie.split(";")[0]!.split("=")[1]!;
    assert.equal(validSession(session), true);
    const crmRequest = new Request("https://edgecare.example/referrals", { headers: { cookie } });
    assert.equal(accessGuard(crmRequest, "clinician"), undefined);
    assert.equal(accessGuard(crmRequest, "issuer")?.status, 401);
    assert.equal(accessGuard(new Request("https://edgecare.example/referrals"), "clinician")?.status, 401);
    assert.equal(accessGuard(new Request("https://edgecare.example/referrals", {
      headers: { authorization: "Bearer issuer-device-only" },
    }), "issuer"), undefined);
    assert.equal((await POST(new Request("https://edgecare.example/demo/session", {
      method: "POST", headers: { origin: "https://attacker.example" },
    }))).status, 403);
    assert.equal((await POST(new Request("http://localhost/demo/session", {
      method: "POST", headers: { origin: "https://edgecare.example", host: "localhost" },
    }))).status, 403);
    process.env.DEMO_MODE = "false";
    assert.equal((await POST(new Request("https://edgecare.example/demo/session", { method: "POST" }))).status, 503);
  } finally {
    for (const key of Object.keys(values)) { if (previous[key] === undefined) delete process.env[key]; else process.env[key] = previous[key]; }
  }
});
