# Edge-Care

Junction 2026 monorepo scaffold for four anonymous cancer-care demo applications. Start with [API.md](API.md), the shared integration contract, and [the project brief](docs/project-brief.md).

| App | Stack | Scaffold |
| --- | --- | --- |
| `apps/kiosk-ios` | Swift 6, SwiftUI, MVVM, iPad/iOS 17+ | Language selection and typed intake shell |
| `apps/crm-web` | Next.js, strict TypeScript, Tailwind | Working referral browser, filters, details, polling and local REST/SQLite backend |
| `apps/doctor-ios` | Swift 6, SwiftUI, MVVM, iOS 17+ | Anonymous referral selection and verification shell |
| `apps/patient-ios` | Swift 6, SwiftUI, MVVM, iPhone/iOS 17+ | Shared intake and wallet shell |

Shared Swift models, crypto, signature matching, persistent mock registry, verification service and enrollment outbox live in `packages/edgecare-core`. TypeScript models, validation, read projections, JSON Schema and deterministic fixtures live in `packages/shared-types`. The Anchor scaffold is in `programs/edgecare-registry`; `demo/remotion` reserves the video workspace.

## Run the CRM and local backend

Requires Node 22.11+ and pnpm 9.15.9.

```sh
corepack enable
pnpm install
cp apps/crm-web/.env.example apps/crm-web/.env.local
pnpm dev
```

Open http://127.0.0.1:3000. Three synthetic referrals seed automatically. SQLite persists under `apps/crm-web/.data/`. The backend exposes `/health`, `/referrals`, `/referrals/:id`, and `/referrals/:id/verification`; there is no separate backend process. The demo guard requires `DEMO_MODE=true`, `CHAIN=mock`, `LLM=ondevice`. Authentication and production adapters are not implemented; keep this local with synthetic data.

```sh
pnpm check       # strict types + protocol/repository/route tests
pnpm build       # production web compilation
pnpm start      # serves the compiled build on loopback
pnpm schema     # regenerate the JSON wire schema
```

`node scripts/generate-fixtures.mjs` regenerates identical Swift/TypeScript fixtures. Fixture crypto uses known PIN `1234` and fixed test nonces; never use those keys/nonces for runtime enrollment. The expiry dates are fixed for reproducibility.

## Open the three native apps

On macOS with Xcode 16+ (Swift 6) and XcodeGen 2.42+:

```sh
brew install xcodegen
pnpm ios:generate
open EdgeCare.xcodeproj
pnpm test:swift
```

Select `EdgeCareKiosk`, `EdgeCareDoctor` or `EdgeCarePatient`, then an appropriate iOS simulator. For physical devices set your signing team in Xcode. All three targets depend on the local Swift package. Native composition roots default to `AppConfiguration.demo`; live adapters require explicit wiring and cannot silently activate in demo/offline mode.

## Registry

Install Rust, Solana/Agave and Anchor 0.32.1, then run `cargo test -p edgecare-registry` and `anchor build`. The checked-in program ID is a placeholder; run `anchor keys sync` after generating deployment keys. No devnet deployment, funded wallets or production credentials are included. The stored verifier signer authorizes spending; the program does not verify biometrics itself.

## Scope and next slices

This is the architecture scaffold, not the finished clinical demo. Next: connect signature/passcode enrollment and verification UI; implement encrypted patient wallet/keychain lifecycle, on-device speech/vision and translated triage; wire devnet signing/status reconciliation and offline conflicts; then apply the two authoritative design documents and produce the video. See [architecture](docs/architecture.md) and [decisions](docs/decisions.md) for the boundaries and brief ambiguities resolved here.

UI uses neutral/native defaults until AstraZeneca branding and Apple styling documents arrive. No actual medical triage or diagnosis is performed.
