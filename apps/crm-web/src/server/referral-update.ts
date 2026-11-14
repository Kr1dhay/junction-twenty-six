import { isDeepStrictEqual } from "node:util";
import type { ReferralRecord } from "@edgecare/shared-types";

const identityFields = ["referral_id", "created_at", "source", "kiosk_id", "signature_template_encrypted", "salt", "commitment_hash", "status", "expires_at"] as const;
export function preservesReferralIdentity(expected: ReferralRecord, record: ReferralRecord) {
  return identityFields.every(key => isDeepStrictEqual(expected[key], record[key]));
}
