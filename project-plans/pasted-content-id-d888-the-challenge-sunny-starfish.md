# Live Supply Chain Map on CRACI

## Context
We want to enter the CRACI challenge at Junction 2026. To qualify, CI has to run on CRACI (`runs-on: craci`). Judging is 50% technical depth and 50% creative use of CRACI features (SBOMs, provenance, network traces, the API). We are building a **live supply chain map**: a force-directed graph of every package across our CRACI builds. Packages are coloured by CVE severity, outlined when they reached the network during the build, and linked to the hosts they came from. Two features go beyond a plain picture:
- **"New since last build"**: packages that appear for the first time are flagged, which is how you would catch a malicious package as it arrives.
- **Unattributed traffic**: network calls that don't match any SBOM component are shown in red, which is how you would spot exfiltration or a build pulling in something it didn't declare.

### What the CRACI API actually gives us (checked against api.craci.com/openapi.json)
- `GET /v1preview1/sbom?provider=github&repo=&job_id=`: CycloneDX 1.7 SBOM per job. The body schema isn't documented, so the parser must be defensive.
- `GET /v1preview1/network-trace?provider=github&repo=&job_id=`: `observations[]` with `protocol` http|dns|tcp|ssh_git. HTTP observations have `originUrl`, `ipAddress`, `policyDenied`, `bodyHash`. TCP observations have `resolvedHosts` and `tlsServerName`. Nothing links an observation to a process or package.
- `GET /v1preview1/jobs?status=active`: **active jobs only**, so we have to find past jobs through the GitHub Actions API (runs → jobs, filtered to the `craci` label).
- `GET /v1preview1/artifact-provenance/gha_cache`: the job that created a cache entry. We use it to draw cache-inheritance edges.
- **No CVE or AI-fix endpoints.** We get CVEs from OSV.dev `POST /v1/querybatch` by purl, which needs no key. AI fixes stay in the CRACI platform UI, and the map deep-links to each job's `url`.
- Auth: `Authorization: Bearer $CRACI_API_TOKEN`. There is no pagination.

## Approach

### 1. Move CI onto CRACI (`.github/workflows/ci.yml`)
- `web` and `registry`: `ubuntu-latest` → `craci`. Add `cracicorp/setup@v1` with `size: "4"` to `web`, because it runs a Next build and Playwright.
- `apple` stays on `macos-15`, since CRACI is Linux only.
- Add a **monitored egress policy** to `registry` (Cargo only, so it's low risk): `network: { default: deny }` with the default presets. Its SBOM can then show as *Complete*, and denied requests appear in the trace (`policyDenied`), which gives the graph real red edges. `web` stays on the default allow policy so Playwright and browser downloads keep working.

### 2. Server: CRACI + GitHub + OSV clients (`apps/crm-web/src/server/`)
- `craci.ts`: a small typed client with `fetchSbom`, `fetchNetworkTrace`, `fetchActiveJobs` and `fetchCacheProvenance`. It takes an injectable `fetcher` so tests can supply a fake, the same pattern as `skin-assessment.ts` and its test. It reads `CRACI_API_TOKEN` and `CRACI_REPO` (default `Kr1dhay/junction-twenty-six`).
- `github-jobs.ts`: lists the last N workflow runs and their jobs through the GitHub REST API (`GITHUB_TOKEN`, read-only actions scope) and keeps jobs whose `labels` include `craci`. Returns `{jobId, runId, name, sha, branch, startedAt, url}`.
- `osv.ts`: batches purls into OSV `querybatch` in chunks of 1000, then fetches `/v1/vulns/{id}` to get severity. Results are cached in memory by purl.
- `supply-chain.ts`: the pure graph builder, with no I/O:
  - **Nodes**: `job` (one per build), `package` (deduplicated by purl, ecosystem taken from the purl type), `host` (from HTTP `originUrl` host, TCP `tlsServerName`, or DNS record).
  - **Edges**: `job→package` (in that job's SBOM). `package→package` (from CycloneDX `dependencies[]`, when present). `package→host` (matched by mapping the URL to a purl: `registry.npmjs.org/<name>/-/<name>-<v>.tgz`, `files.pythonhosted.org/.../<name>-<v>`, `static.crates.io/crates/<name>/<v>`, `codeload.github.com/<owner>/<repo>`, ghcr/docker blobs by digest). `job→host` for traffic that didn't match any package (**unattributed**). `job→job` for cache inheritance (via gha_cache provenance).
  - **Per-package fields**: `vulns[]` with max severity, `firstSeenJob`, `isNew` (absent from every earlier job), `touchedNetwork`, `jobs[]` (blast radius).
  - **Summary stats**: package count, critical/high counts, new packages, unattributed hosts, denied requests, and SBOM completeness when the SBOM reports it.
- `scripts/supply-chain-snapshot.ts` (`pnpm supply-chain:snapshot`): runs the whole pipeline and writes `apps/crm-web/data/supply-chain.json`. This follows the existing `pathway:snapshot` and `twin:snapshot` pattern, so the stage demo still works offline or without keys.
- Add a "Supply chain map" entry to `src/server/env-check.ts` that lists `CRACI_API_TOKEN` and `GITHUB_TOKEN` (names only).

### 3. API route
- `src/app/supply-chain/data/route.ts` (`runtime = "nodejs"`, `dynamic = "force-dynamic"`):
  - If the keys are set, it returns live data, cached for about 60s in memory.
  - Otherwise it returns the committed snapshot, marked `source: "snapshot"`.
  - `?job=<id>` returns the graph as of that job, which drives the timeline scrubber.
  - Uses the `json` helper from `src/server/http.ts`.
  - Never sends tokens to the client.

### 4. UI: `/supply-chain` page in crm-web
- New dependency: `d3-force`, for the physics simulation only. Drawing is done on canvas (with an SVG overlay for labels) so a few thousand nodes stay smooth.
- `src/app/supply-chain/page.tsx` plus `supply-chain-map.tsx` (client component) and `supply-chain.module.css`. It uses the existing tokens in `globals.css` (`--mulberry`, `--magenta`, `--rose`, …) and the existing `risk-badge` colours.
- Layout:
  - Top stats strip, reusing the `.overview` pattern.
  - Large graph canvas.
  - Right-hand detail panel, reusing the `.detail-panel` pattern.
  - Bottom **build timeline scrubber**: one tick per CRACI job. Scrubbing animates packages in and out, with new ones pulsing.
- Encoding:
  - Node fill: no CVE (neutral), low, medium, high, critical.
  - Outline ring: the package touched the network.
  - Host nodes: diamonds. Registry hosts are grey; unattributed or denied hosts are red.
  - Job nodes: large hubs.
- Interactions:
  - Click a package to see its CVEs (with OSV links), which jobs and builds contain it (blast radius), the host it came from with the body hash, and a deep link to the CRACI job.
  - Filters: ecosystem, "only vulnerable", "only new", "only network".
  - Search by package name.
- Add a nav link next to the equity link in the workspace sidebar.

### 5. Tests (`apps/crm-web/tests/supply-chain.test.ts`, using node:test like the existing tests)
- Graph builder from fixture SBOMs and traces covers: deduplication across jobs, URL→purl matching for npm, PyPI and crates, unattributed hosts, `isNew` diffing, and the highest severity winning.
- CRACI and OSV clients with fake fetchers: auth header is set, purls are batched, and errors are handled.
- Route: falls back to the snapshot when the keys are missing.

## Critical files
- `.github/workflows/ci.yml` (modify)
- `apps/crm-web/src/server/{craci,github-jobs,osv,supply-chain}.ts` (new)
- `apps/crm-web/src/server/env-check.ts` (modify)
- `apps/crm-web/src/app/supply-chain/{page.tsx,data/route.ts}` (new). The client component and CSS go in `src/components/supply-chain-map.tsx` and `supply-chain.module.css`, matching the `equity-actions.tsx` + `equity-visuals.module.css` pattern.
- Sidebar nav: add the link wherever the equity nav link lives (`src/components/referral-dashboard.tsx`).
- Playwright smoke test: `tests/supply-chain.spec.ts` checks that the page renders from the snapshot.
- `scripts/supply-chain-snapshot.ts`, `apps/crm-web/data/supply-chain.json` (new). Add the `supply-chain:snapshot` script to the root `package.json`.
- `apps/crm-web/package.json`: add `d3-force` and `@types/d3-force`.

## Once keys arrive
1. Pull one real SBOM and one real trace and save them as test fixtures. Adjust the parser to the actual CycloneDX 1.7 shape, including any CRACI-specific `properties` such as cache origin or completeness, and use them if they are present.
2. Run `pnpm supply-chain:snapshot` and commit the snapshot.

## Verification
- `pnpm check` (typecheck plus node:test) passes, including the new tests.
- Push a branch and confirm the `web` and `registry` jobs pick up CRACI runners and the builds appear in platform.craci.com.
- With `CRACI_API_TOKEN` and `GITHUB_TOKEN` in `apps/crm-web/.env.local`: `pnpm env:check` shows the feature as OK, `pnpm dev`, then open `/supply-chain`. Expect real jobs, packages coloured by OSV severity, and hosts from the trace.
- Demo check: add a throwaway dependency on a branch, push, and confirm it shows as **new** on the timeline. A request to a non-registry host (for example `curl example.com` in a step) should show as an **unattributed** red host.
- Without keys, the page renders from the snapshot.
