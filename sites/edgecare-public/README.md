# Edge-Care public website

Independent, static marketing site for the Edge-Care synthetic prototype and proposed community pilot. This checkout is separate from the clinical demonstration applications.

## Preview

Run `node serve.mjs` and visit http://127.0.0.1:4317.

## Contents

- `dist/index.html`: solution, audience, kiosk/doctor/web app screenshots (including one per journey step) and direct demo links, evidence and partner brief.
- `dist/pilot.html`: proposed pilot and evaluation.
- `dist/privacy.html`: demonstration and website privacy information.
- `dist/app.js`: navigation, accessible journey tabs, copyable discussion outline.
- `dist/partner-brief.md`: downloadable partnership brief.

No contact email was supplied. The partnership section provides a download and copyable outline rather than a form. No backend, health-data collection, external analytics, AI calls or real booking integration is included.

Hosting identity is retained in `.openai/hosting.json`. Use the Sites source workflow for subsequent publication.

Screenshot provenance: dist/assets images were captured on 15 November 2026 from the running apps using synthetic data only. `kiosk-*.jpg` come from the EdgeCareKiosk iPad app (iPad Air 13-inch simulator, landscape) and `doctor-*.jpg` from the EdgeCareDoctor iPhone app (iPhone 17 simulator). Both apps were connected to a local crm-web backend with `EDGECARE_TEST_FIXTURES=true`. The `clinical-workspace.png`, `equity-actions.png` and `digital-twin.png` images come from that same local crm-web at 1440×1000. No referral was enrolled and no microphone audio was captured; the voice screen uses the `EDGECARE_VOICE_REVIEW_PHASE=listening` review state. The public marketing site links directly to https://edgecare-lissankoiralas-projects.vercel.app/.
