# Hosted Edge-Care demo

Production URL: [Edge-Care clinician workspace](https://edgecare-lissankoiralas-projects.vercel.app). Use this canonical hostname for both the browser and native app API.

The `edgecare` Vercel project serves the CRM and native-app API. Neon Postgres on the Free plan in Frankfurt stores encrypted referrals and the shared demo registry. SQLite remains the local adapter. Hosting does not turn this demonstration into a validated clinical service or a deployed Solana registry.

Production settings are server-side Vercel environment variables: `DATABASE_URL`, `EDGECARE_SESSION_SECRET`, issuer/clinician tokens, `EDGECARE_PUBLIC_ORIGIN`, `RUNWARE_API_KEY`, `VOICE_LLM_PROVIDER=runware`, `RUNWARE_MODEL=google:gemini@3-flash`, and ElevenLabs key/models/language voices. `DEMO_MODE=true`, `CHAIN=mock`, `LLM=ondevice` keep the synthetic demo adapters enabled; explicit `EDGECARE_CLOUD_VOICE=true` opts into cloud intake. Provider keys, database credentials and the session-signing secret are excluded from Git. The hosted demo's device access tokens are supplied in the repository's `edgecare-device.json`.

Every mutation for a referral holds a Postgres transaction lock. Concurrent consumption has one winner, and retrying that winning operation remains idempotent. Hosted sessions use a stable server signing secret across instances. HTTPS origin checks and device tokens protect the API. `/health` checks the database and exposes no credentials.

## Connect existing Mac simulators

From the repository on your Mac, with the simulators booted, use the committed device configuration:

```sh
git pull --ff-only
python3 scripts/connect-hosted.py --config edgecare-device.json
```

The command verifies backend health and relaunches installed kiosk, doctor and patient apps with connected mode and the HTTPS URL. It does not require a local server, credential wizard or native rebuild. It reports the actual simulator runtimes already running. Xcode Run may reset the environment to offline defaults; rerun the command after doing that.

When native code changes, append `--rebuild` to run Swift tests, regenerate the Xcode project, build and reinstall the apps on those same booted simulators before connecting. This is required for the hands-free voice update. Build logs are saved under `artifacts/hosted-build/`.

The browser CRM requires the clinician demo token from the same private configuration. A native patient must still consent before any audio or text is sent to providers. Physical devices need their own Xcode signing/install and the same connected environment settings.

## Verify and redeploy

`pnpm exec tsx scripts/verify-hosted.ts` uses privately configured device tokens and the HTTPS origin to verify auth, enrollment, persistent status, concurrent consumption and privacy. It creates one clearly synthetic test referral. `--live-voice` additionally makes billed provider calls for five languages, profile correction and automatic speech detection, and requires the synthetic English audio fixture under `artifacts/voice-probes/en.mp3`. Reports contain synthetic results, never credentials.

`EDGECARE_TEST_DATABASE_URL` opts into the real Postgres repository test, which cleans up only its generated IDs. Normal tests do not touch the hosted database. A new server instance initializes the schema lazily and does not insert local fixture records.

Vercel's GitHub integration could not access this repository during setup, so deployments use uploaded source files. A Git push alone does not redeploy. The project root is `apps/crm-web`, with monorepo sources outside that directory enabled, Node 22, and `pnpm install --frozen-lockfile`. Run the checks before deploying through Vercel. Do not use a temporary filesystem as a replacement for `DATABASE_URL`.
