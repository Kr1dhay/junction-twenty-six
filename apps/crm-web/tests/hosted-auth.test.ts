import test from "node:test";
import assert from "node:assert/strict";
import { accessGuard, createSession, isLoopback, sameOrigin, validSession } from "../src/server/auth";

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
