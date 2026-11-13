import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createDecipheriv, createHash, hkdfSync } from "node:crypto";
import { referralSchema, toCRMReferral } from "../src/index";
import { demoReferrals } from "../src/fixtures";

test("Swift and TypeScript consume the same wire fixtures", () => {
  const swift = readFileSync("packages/edgecare-core/Sources/EdgeCareCore/Resources/referrals.json", "utf8");
  const typescript = readFileSync("packages/shared-types/fixtures/referrals.json", "utf8");
  assert.equal(swift, typescript);
  for (const record of JSON.parse(swift)) assert.ok(referralSchema.safeParse(record).success);
});
test("CRM projection cannot expose enrollment secrets or source metadata", () => {
  const publicRecord = toCRMReferral(demoReferrals[0]!);
  for (const field of ["signature_template_encrypted", "triage_detail_encrypted", "salt", "commitment_hash", "source", "kiosk_id"])
    assert.ok(!(field in publicRecord), field);
});
test("wire validation rejects identities, malformed crypto fields and invalid risk", () => {
  const record = demoReferrals[0]!;
  for (const patch of [{ name: "Not allowed" }, { risk_score: 101 }, { salt: "bad" }, { commitment_hash: "xyz" }, { expires_at: record.created_at }])
    assert.equal(referralSchema.safeParse({ ...record, ...patch }).success, false);
});
test("fixture follows the documented HKDF, AES-GCM and SHA-256 protocol", () => {
  const record = demoReferrals[0]!;
  const salt = Buffer.from(record.salt, "base64");
  const key = hkdfSync("sha256", Buffer.from("1234"), salt, Buffer.from("edgecare.referral.v1"), 32);
  const sealed = Buffer.from(record.signature_template_encrypted, "base64");
  const decipher = createDecipheriv("aes-256-gcm", Buffer.from(key), sealed.subarray(0, 12));
  decipher.setAuthTag(sealed.subarray(-16));
  const template = Buffer.concat([decipher.update(sealed.subarray(12, -16)), decipher.final()]);
  const expected = createHash("sha256").update(Buffer.concat([createHash("sha256").update(template).digest(), Buffer.from("1234"), Buffer.from(record.referral_id), salt])).digest("hex");
  assert.equal(record.commitment_hash, expected);
  assert.equal(JSON.parse(template.toString()).points.length, 32);
});
