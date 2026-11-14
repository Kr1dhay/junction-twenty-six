# Solana commitment registry

Anchor 0.32.1 program stores a hash, verifier authority, spent flag and slots at a UUID-seeded PDA. Only the chosen verifier can spend. It does not attest that an issuer is a registered clinic or validate a biometric proof.

```sh
cargo test -p edgecare-registry
anchor build
anchor keys sync
anchor build
```

Generate/fund local devnet keypairs and deploy using your own Solana toolchain. No private keys, funded accounts or deployed program are bundled. Never use mainnet for this demo.

The real RPC CLI is separate from the native connected-demo mock transport:

```sh
export DEMO_MODE=false CHAIN=devnet
export EDGECARE_PROGRAM_ID=YOUR_DEPLOYED_PROGRAM_ID
export SOLANA_KEYPAIR=/absolute/path/to/local-keypair.json
export EDGECARE_VERIFIER_PUBLIC_KEY=YOUR_VERIFIER_PUBLIC_KEY
pnpm registry create REFERRAL_UUID COMMITMENT_HASH
pnpm registry read REFERRAL_UUID
# Use the verifier's keypair only after off-chain verification:
pnpm registry spend REFERRAL_UUID COMMITMENT_HASH
```

RPC is restricted to devnet or localhost; duplicate creates are checked idempotently, mismatched hashes/authorities reject, repeated spends reject. Program ownership/discriminators are checked before decoding. The CLI signs real transactions and waits for confirmation, but no deployment or network transaction has been tested in this workspace. Native apps use the shared HTTP demo registry until a deployed-chain signer/RPC integration is configured.
