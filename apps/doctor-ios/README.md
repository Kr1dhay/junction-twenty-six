# Doctor verification

Run the `EdgeCareDoctor` target generated from root `project.yml`, or use the root Apple demo launcher. The app lists anonymous referrals, looks up and caches a full referral ID, and collects the patient's four-digit code and fresh signature. Shared core code decrypts the enrollment, matches the signature, checks the commitment and spends once. Secrets clear after submission, navigation, backgrounding, or two minutes of inactivity.

The result distinguishes local-device verification, shared-registry confirmation, provisional offline spending, and conflicts discovered during synchronization. The referral list refreshes every eight seconds while active. Offline verification requires an enrollment and commitment previously cached on that doctor device. The toolbar can simulate offline; reconnecting reconciles pending spends, with first accepted use winning.

`EDGECARE_MODE=local` is network-free and seeds synthetic fixtures; use the clearly labelled sample signature with code `1234` only for those synthetic records. Standalone local registries on different apps/devices do not share state. `EDGECARE_MODE=connected` uses the one backend at `EDGECARE_BASE_URL` with `EDGECARE_CLINICIAN_TOKEN` (legacy `EDGECARE_API_TOKEN` accepted) and optional `EDGECARE_ISSUER_TOKEN`. This is an explicitly labelled HTTP demo registry, not a Solana devnet deployment.

Matching is an experimental demo aid, not a validated biometric or official care authorization. See `API.md` for protocol/security limits. The Linux implementation host had no Xcode/Apple SDK; native compilation and actual device behavior remain to be checked on a Mac.
