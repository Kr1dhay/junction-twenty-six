import test from "node:test";
import assert from "node:assert/strict";
import { PublicKey } from "@solana/web3.js";
import { decodeCommitment, discriminator, uuidBytes } from "../registry";

test("Anchor UUID seed and account bytes decode with exact flags and slots", () => {
  const id = "00000000-0000-4000-8000-000000000001";
  assert.equal(uuidBytes(id).length, 16);
  assert.throws(() => uuidBytes("not-a-uuid"));
  const data = Buffer.alloc(90);
  discriminator("account", "CommitmentAccount").copy(data);
  Buffer.alloc(32, 7).copy(data, 8);
  const verifier = new PublicKey("11111111111111111111111111111111");
  verifier.toBuffer().copy(data, 40);
  data[72] = 1; data.writeBigUInt64LE(12n, 73); data[81] = 1; data.writeBigUInt64LE(15n, 82);
  assert.deepEqual(decodeCommitment(data), { commitment_hash: "07".repeat(32), verifier: verifier.toBase58(), spent: true, created_slot: "12", spent_slot: "15" });
  data[81] = 2;
  assert.throws(() => decodeCommitment(data), /flags/);
  assert.throws(() => decodeCommitment(Buffer.alloc(90)), /discriminator/);
});
