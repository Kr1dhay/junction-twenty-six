# Scaffold verification

Verified on the supplied Linux host with Node 22.11.0 and pnpm 9.15.9:

- `pnpm check`: strict TypeScript passes; all 9 contract, crypto-vector, repository and route tests pass.
- `pnpm build`: Next.js production build succeeds for the CRM and all four API route patterns.
- Live HTTP smoke: CRM returns 200 and its page shell; health returns 200; SQLite serves 3 seeded referrals; public responses omit source/crypto fields; detail retrieval succeeds; resubmission returns 200 without duplication.
- `pnpm schema`: JSON Schema regenerates successfully; Swift and TypeScript fixture files are identical.

Not verified on this host: Swift compilation/tests, iOS simulator interaction, Anchor/Rust compilation/tests, or browser interaction. The required Swift/Xcode/Rust/Anchor tools are not installed. CI defines macOS Swift tests and simulator builds plus Rust unit tests; those jobs have not been run here. The Anchor unit test covers the spent-state transition, not validator-level signer constraints.

No deployment or devnet transaction was performed. Native screens are architecture shells; enrollment capture, clinical intelligence, wallet and cross-device reconciliation remain integration work.
