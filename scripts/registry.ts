/** Explicit opt-in Solana devnet/local-validator adapter. Never called by offline demo mode. */
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { Connection, Keypair, PublicKey, SystemProgram, Transaction, TransactionInstruction, sendAndConfirmTransaction } from "@solana/web3.js";

export function uuidBytes(id: string): Buffer {
  if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(id)) throw new Error("Expected a lowercase referral UUID");
  return Buffer.from(id.replaceAll("-", ""), "hex");
}
export function discriminator(namespace: string, name: string): Buffer {
  return createHash("sha256").update(`${namespace}:${name}`).digest().subarray(0, 8);
}
export function decodeCommitment(data: Buffer) {
  if (data.length < 82 || !data.subarray(0, 8).equals(discriminator("account", "CommitmentAccount"))) throw new Error("Invalid registry account discriminator or size");
  const option = data[81];
  if ((data[72] !== 0 && data[72] !== 1) || (option !== 0 && option !== 1) || (option === 1 && data.length < 90)) throw new Error("Invalid registry account flags");
  return { commitment_hash: data.subarray(8, 40).toString("hex"), verifier: new PublicKey(data.subarray(40, 72)).toBase58(),
    spent: data[72] === 1, created_slot: data.readBigUInt64LE(73).toString(), spent_slot: option === 1 ? data.readBigUInt64LE(82).toString() : null };
}

async function main() {
  const [action, id, hash] = process.argv.slice(2);
  if (!["read", "create", "spend"].includes(action ?? "") || !id) throw new Error("Usage: pnpm registry read|create|spend REFERRAL_UUID [COMMITMENT_HASH]");
  if (process.env.DEMO_MODE !== "false" || process.env.CHAIN !== "devnet") throw new Error("Explicitly set DEMO_MODE=false and CHAIN=devnet to enable registry RPC");
  const programAddress = process.env.EDGECARE_PROGRAM_ID;
  if (!programAddress || programAddress === "Fg6PaFpoGXkYsidMpWxTWqkZqkGmWcVJ9B8XhKfP7rD") throw new Error("Set EDGECARE_PROGRAM_ID to your deployed registry program ID");
  const rpc = process.env.SOLANA_RPC_URL ?? "https://api.devnet.solana.com";
  const rpcURL = new URL(rpc);
  if (!(rpcURL.hostname === "api.devnet.solana.com" || ["localhost", "127.0.0.1"].includes(rpcURL.hostname))) throw new Error("This demo CLI only permits Solana devnet or a local validator");
  const connection = new Connection(rpc, "confirmed");
  const program = new PublicKey(programAddress);
  const info = await connection.getAccountInfo(program);
  if (!info?.executable) throw new Error("Configured registry program is not deployed/executable on this RPC");
  const referralID = uuidBytes(id);
  const [address] = PublicKey.findProgramAddressSync([Buffer.from("commitment"), referralID], program);
  const account = await connection.getAccountInfo(address);
  if (account && !account.owner.equals(program)) throw new Error("Registry account has an unexpected owner");
  const existing = account ? decodeCommitment(account.data) : undefined;
  if (action === "read") {
    console.log(JSON.stringify({ address: address.toBase58(), account: existing ?? null }, null, 2)); return;
  }
  if (!hash || !/^[a-f0-9]{64}$/.test(hash)) throw new Error("A 32-byte lowercase commitment hash is required");
  const keyPath = process.env.SOLANA_KEYPAIR;
  if (!keyPath) throw new Error("Set SOLANA_KEYPAIR to the local issuer/verifier keypair file; never commit it");
  const bytes: unknown = JSON.parse(readFileSync(keyPath, "utf8"));
  if (!Array.isArray(bytes) || bytes.length !== 64 || !bytes.every(value => Number.isInteger(value) && value >= 0 && value <= 255)) throw new Error("Invalid Solana keypair file");
  const signer = Keypair.fromSecretKey(Uint8Array.from(bytes as number[]));
  let instruction: TransactionInstruction;
  if (action === "create") {
    const verifier = new PublicKey(process.env.EDGECARE_VERIFIER_PUBLIC_KEY ?? signer.publicKey.toBase58());
    if (existing) {
      if (existing.commitment_hash !== hash || existing.verifier !== verifier.toBase58()) throw new Error("Referral ID already registered with different content");
      console.log(JSON.stringify({ address: address.toBase58(), status: "already_created", spent: existing.spent })); return;
    }
    instruction = new TransactionInstruction({ programId: program,
      keys: [{ pubkey: address, isSigner: false, isWritable: true }, { pubkey: signer.publicKey, isSigner: true, isWritable: true }, { pubkey: SystemProgram.programId, isSigner: false, isWritable: false }],
      data: Buffer.concat([discriminator("global", "create_commitment"), referralID, Buffer.from(hash, "hex"), verifier.toBuffer()]) });
  } else {
    if (!existing || existing.commitment_hash !== hash) throw new Error("Missing commitment or hash mismatch");
    if (existing.spent) throw new Error("Commitment already spent; replay rejected");
    if (existing.verifier !== signer.publicKey.toBase58()) throw new Error("This signer is not the registered verifier");
    instruction = new TransactionInstruction({ programId: program,
      keys: [{ pubkey: address, isSigner: false, isWritable: true }, { pubkey: signer.publicKey, isSigner: true, isWritable: false }],
      data: Buffer.concat([discriminator("global", "spend_commitment"), referralID]) });
  }
  const signature = await sendAndConfirmTransaction(connection, new Transaction().add(instruction), [signer], { commitment: "confirmed" });
  console.log(JSON.stringify({ address: address.toBase58(), signature, status: "confirmed" }, null, 2));
}

// Avoid invoking RPC when encoding/decoding helpers are imported by tests.
if (process.argv[1]?.endsWith("registry.ts")) main().catch(error => { console.error(error instanceof Error ? error.message : "Registry request failed"); process.exitCode = 1; });
