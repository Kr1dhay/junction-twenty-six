import { createDecipheriv, createHash } from "node:crypto";
import type { ReferralRecord } from "@edgecare/shared-types";

export class OwnershipError extends Error {}
// Tombstones retain no referral ID, credentials or health information.
export const deletedID = (id: string) => createHash("sha256").update(id).digest("hex");

/** Validate knowledge of the record encryption key, separately from device authorization.
 * Native code releases it only after a fresh code AND signature match (no debug bypass).
 * Authenticate the sealed clinical payload, never the biometric template. The key and
 * transient plaintext are not logged or persisted. Swift AES.GCM combined = nonce|body|tag.
 */
export function verifyDeletionKey(record: ReferralRecord, encoded: string) {
  const key = Buffer.from(encoded, "base64");
  let plaintext: Buffer | undefined;
  try {
    const sealed = Buffer.from(record.triage_detail_encrypted, "base64");
    if (key.length !== 32 || sealed.length < 28) throw new Error("Invalid proof");
    const decipher = createDecipheriv("aes-256-gcm", key, sealed.subarray(0, 12));
    decipher.setAuthTag(sealed.subarray(-16));
    plaintext = decipher.update(sealed.subarray(12, -16));
    decipher.final();
  } catch { throw new OwnershipError("Verify your code and signature again before deleting"); }
  finally { key.fill(0); plaintext?.fill(0); }
}
