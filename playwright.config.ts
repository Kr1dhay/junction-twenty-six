import { defineConfig } from "@playwright/test";
import { tmpdir } from "node:os";
import { join } from "node:path";

export default defineConfig({
  testDir: "./tests",
  workers: 1,
  timeout: 60_000,
  expect: { timeout: 12_000 },
  reporter: "list",
  use: {
    baseURL: "http://127.0.0.1:4317",
    viewport: { width: 1600, height: 1100 },
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
    launchOptions: process.env.EDGECARE_TEST_CHROME ? { executablePath: process.env.EDGECARE_TEST_CHROME, args: ["--no-sandbox", "--disable-dev-shm-usage"] } : {},
  },
  webServer: {
    command: `pnpm --filter @edgecare/crm-web exec next ${process.env.EDGECARE_TEST_DEV === "true" ? "dev" : "start"} --hostname 127.0.0.1 --port 4317`,
    url: "http://127.0.0.1:4317/health",
    reuseExistingServer: false,
    timeout: 120_000,
    env: { DEMO_MODE: "true", CHAIN: "mock", LLM: "ondevice", EDGECARE_CLINICIAN_TOKEN: "", EDGECARE_ISSUER_TOKEN: "", EDGECARE_PUBLIC_ORIGIN: "", DATABASE_URL: "", VERCEL: "", EDGECARE_CLOUD_VOICE: "false", EDGECARE_PUBLIC_DATA: "snapshot", EDGECARE_TEST_FIXTURES: "true", EDGECARE_SESSION_SECRET: "synthetic-browser-session-secret-for-tests-only", EDGECARE_DB_PATH: join(tmpdir(), `edgecare-browser-${process.pid}.sqlite`) },
  },
});
