# Implementation verification

Verified on the supplied Linux host with Node 22.11.0 and pnpm 9.15.9:

- `pnpm typecheck`: strict TypeScript passes for the CRM, shared models, Remotion composition, devnet CLI and browser-test configuration.
- `pnpm test`: all 21 tests pass. Coverage includes wire privacy/crypto, enrollment idempotency, persistence, concurrent SQLite spend arbitration across separate processes, winning-operation replay after restart, auth/origin guards, voice provider contracts and Anchor byte encoding.
- `pnpm test:launcher`: four simulator-selection tests pass; missing exact runtimes/device types do not silently fall back.
- `pnpm build`: production CRM/API build passes, including conversation and profile-normalization routes.
- `pnpm schema`: generated referral schema is unchanged; Swift and TypeScript consume matching fixtures.
- Browser integration against a production server: login, filters, live enrollment arrival, shared spend propagation, retry acceptance/competing-spend rejection, privacy projection, stale-data display during a lost connection, reconnect and logout pass. Desktop/mobile screenshots are under ignored `artifacts/browser/`. Responsive filter and tablet logout regression checks are included.
- Independent Python HKDF/AES-GCM/SHA-256 verification matches all three bundled Swift/TypeScript fixture commitments.

Voice provider tests use mocked responses. They verify omitted STT language hints, confidence handling, English profile transport, selected language-specific voice, language mismatches, unavailable providers and consent gates. They do not verify live language recognition, translation quality or actual synthesized audio. No live provider requests were made.

Not executable on this host: Swift/Xcode native builds, the 20 shared Swift tests, simulator interaction, physical-device behavior, Anchor/Rust compilation or devnet transactions. The Mac launcher performs Swift tests and native builds before launch; CI defines macOS simulator builds and Rust tests, but those jobs have not been run here. No exact iOS/iPadOS 27.2.1 device run is claimed.

Remotion TypeScript and bundling pass. A still render was attempted but failed on this host: Remotion requires glibc 2.35+ while this Linux installation has 2.31, and the browser-render process was killed. Render the composition on the Mac or a compatible host. No rendered pitch video or recorded native footage is claimed.

Remaining external setup: provider credentials/voice selection, actual Apple device testing, a deployed Solana program and signer for real registry operations, and model assets for any future Nemotron/lesion assessment. Native connected-demo uses the shared HTTP mock registry; it is not a native signed devnet deployment. Scripted priority scores and signature matching are unvalidated demo logic.
