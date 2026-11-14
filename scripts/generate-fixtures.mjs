import { createHash, createCipheriv, hkdfSync } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
// Fixed keys/nonces are test vectors ONLY; runtime enrollment uses CryptoKit randomness.
const passcode = '1234';
const points = Array.from({ length: 32 }, (_, i) => ({ time: 0, x: i / 31, y: i / 31 }));
const template = Buffer.from(JSON.stringify({ points }));
const guidance = {
  so: 'Tani waa tusaale bandhig ah, mana aha ogaansho caafimaad. La xiriir xirfadle caafimaad si loo qiimeeyo isbeddelka maqaarka.',
  fi: 'Tämä on esimerkkitapaus, ei diagnoosi. Pyydä terveyskeskusta selittämään seulontakutsu ja sen toimintaohjeet.',
  en: 'This is a demonstration, not a diagnosis. Ask a local health service about the care available to you.',
};
const records = [
  ['so', 'dermatology', 'high', 75, 'Synthetic example: a changing skin mark, discussed during a demo consultation.'],
  ['fi', 'gynaecology', 'medium', 45, 'Synthetic example: help understanding an invitation to screening.'],
  ['en', 'general practice', 'low', 15, 'Synthetic example: a question about accessing local care.'],
].map(([language, specialty, band, score, summary], index) => {
  const id = `00000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`;
  const salt = Buffer.alloc(16, index + 1);
  const key = hkdfSync('sha256', Buffer.from(passcode), salt, Buffer.from('edgecare.referral.v1'), 32);
  function encrypt(data, marker) {
    const nonce = Buffer.alloc(12, marker);
    const cipher = createCipheriv('aes-256-gcm', key, nonce);
    return Buffer.concat([nonce, cipher.update(data), cipher.final(), cipher.getAuthTag()]).toString('base64');
  }
  const hash = createHash('sha256').update(Buffer.concat([
    createHash('sha256').update(template).digest(), Buffer.from(passcode), Buffer.from(id), salt,
  ])).digest('hex');
  return { referral_id: id, created_at: `2026-11-${14 - index}T09:00:00.000Z`, source: index === 1 ? 'patient_app' : 'kiosk', kiosk_id: null,
    language, symptoms: ['demo_only'], free_text_summary: summary, patient_language_summary: guidance[language],
    risk_score: score, risk_band: band, recommended_specialty: specialty,
    letter_scan: { present: index === 1, extracted_text: index === 1 ? 'Synthetic screening invitation.' : null },
    lesion_photo: { present: false, assessment: null }, signature_template_encrypted: encrypt(template, index * 2 + 1),
    triage_detail_encrypted: encrypt(Buffer.from('{"demo":true}'), index * 2 + 2), salt: salt.toString('base64'), commitment_hash: hash,
    status: 'open', expires_at: index === 2 ? '2026-11-13T10:00:00.000Z' : '2030-01-01T00:00:00.000Z' };
});
for (const path of ['packages/shared-types/fixtures', 'packages/edgecare-core/Sources/EdgeCareCore/Resources']) {
  mkdirSync(path, { recursive: true });
  writeFileSync(`${path}/referrals.json`, JSON.stringify(records, null, 2) + '\n');
}
