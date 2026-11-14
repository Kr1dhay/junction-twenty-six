import { createCipheriv, hkdfSync, randomBytes, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { demoReferrals } from "@edgecare/shared-types/fixtures";
import type { ConsultationRecord } from "@edgecare/shared-types";

export function syntheticProfile() {
  const salt = randomBytes(16);
  // Same HKDF-SHA256 and AES.GCM combined representation as the Swift enrollment code.
  const key = Buffer.from(hkdfSync("sha256", Buffer.from("0123"), salt, Buffer.from("edgecare.referral.v1"), 32));
  const nonce = randomBytes(12), cipher = createCipheriv("aes-256-gcm", key, nonce);
  const sealed = Buffer.concat([nonce, cipher.update('{"concern":"Synthetic deletion test"}'), cipher.final(), cipher.getAuthTag()]);
  return { key: key.toString("base64"), record: { ...demoReferrals[0]!, referral_id: randomUUID(), salt: salt.toString("base64"), triage_detail_encrypted: sealed.toString("base64"), expires_at: "2034-01-01T00:00:00.000Z" } };
}
export function consultationFor(id: string): ConsultationRecord {
  return { ...JSON.parse(readFileSync("packages/shared-types/fixtures/consultation.json", "utf8")), consultation_id: randomUUID(), referral_id: id };
}

