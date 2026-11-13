# Scaffold decisions

1. The existing `junction-twenty-six` repository is the monorepo root (the brief calls it `edgecare/`). No nested Git repository.
2. Next.js hosts both the CRM and the single REST backend. SQLite is the persistent local demo database; interfaces isolate it from a future deployment adapter. No hosting or account provisioning is part of scaffolding.
3. `API.md` was written before scaffolding. The wire schema, TypeScript validation and Swift fixture tests keep the boundary reviewable. JSON field names are snake_case; explicit Codable keys avoid ID acronym mismatches.
4. The CRM is an allowlist projection. Source metadata and all cryptographic material are excluded. Full triage detail has an additional encrypted field; display summaries are intentionally clinician-readable. These anonymous records are still sensitive health data.
5. The three native apps are XcodeGen targets (Swift 6/iOS 17), with MVVM composition roots and a shared `EdgeCareUI` intake module alongside `EdgeCareCore`. Generated Xcode files are ignored.
6. Native configuration defaults to a fully local demo. Gemini, Core ML/Nemotron, devnet signing, speech, capture UI, enrollment orchestration, encrypted wallet and cross-device offline reconciliation are explicit integration work. Unconfigured real adapters throw; they never invent a diagnosis or successful transaction.
7. Local mock verification is provisional. A device without cached records cannot verify an unknown referral offline. The same mock store is persistent on one device; a second device has a separate store. Chain create precedes backend sync; pending items remain durable on failure.
8. The registry adds a verifier public key to the brief's minimal account. Only that signer may spend. It trusts off-chain verification by the clinician; it is not a zero-knowledge biometric proof. Issuer registration, clinician provisioning, anti-spam controls, expiry enforcement and on-chain authorization tests are future deployment work.
9. HKDF-SHA256/AES-GCM implements the brief's allowed demo encryption. A four-digit PIN can be brute-forced offline. Do not describe this as strong identity assurance or assert GDPR compliance. Signature DTW is a demo matcher without validated false-accept/reject rates; timing, pressure and stroke boundaries await refinement.
10. Neither authoritative design markdown was supplied. All screens use plain system styling and explicit brand placeholders. Obtain those documents before UI polish.
11. Anchor is deliberately pinned to 0.32.1 for this scaffold. Its generated IDL and deployment keypair must be produced by the matching toolchain. No devnet deployment has been attempted.
12. SQLite driver 11.10.0 and Tailwind 4.1.18 are pinned for the supplied Node 22.11 / glibc 2.31 development host. Newer releases failed native-library loading and CommonJS/ESM loading respectively during verification. The pnpm lockfile records the tested dependency graph.

Implementation references: [Next.js route handlers](https://nextjs.org/docs/app/getting-started/route-handlers), [Anchor account constraints](https://www.anchor-lang.com/docs/references/account-constraints).
