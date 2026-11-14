# Patient iPhone

Run the `EdgeCarePatient` target generated from root `project.yml`, or use the root Apple demo launcher. It shares the complete kiosk intake (structured offline form or consented online conversation), translated controls, actual signature capture, double code entry and no-reset warning.

The Wallet tab reads the encrypted local wallet, shows enrollment/spend/conflict state and expiry, and presents the full referral ID for clinician handoff. Only the ID is offered to the system share sheet. The PIN is cleared after enrollment and never shown in the wallet. Text, touch and supported on-device dictation provide an offline path; optional online voice requires external-processing consent and server provider configuration. English clinical fields come from the structured catalog or the conversational provider; original-language notes are encrypted separately.

Standalone launch defaults to `EDGECARE_MODE=local`, a network-free device-local demo. For the shared backend use `EDGECARE_MODE=connected`, `EDGECARE_BASE_URL`, `EDGECARE_ISSUER_TOKEN`, and optionally `EDGECARE_CLINICIAN_TOKEN` (or legacy `EDGECARE_API_TOKEN`). Network observation and toolbar offline simulation drive outbox reconciliation. See the kiosk README and `API.md` for details and limitations. No native compilation or device execution was possible on the Linux implementation host.
