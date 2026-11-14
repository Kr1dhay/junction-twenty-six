import { z } from "zod";

const base64 = z.string().regex(/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/).min(4);
export const commitmentRequestSchema = z.object({ commitment_hash: z.string().regex(/^[a-f0-9]{64}$/) }).strict();
export const spendRequestSchema = commitmentRequestSchema.extend({ operation_id: z.string().uuid().optional() }).strict();
export const referralSchema = z.object({
  referral_id: z.string().uuid().transform(value => value.toLowerCase()),
  created_at: z.string().datetime(),
  source: z.enum(["kiosk", "patient_app"]),
  kiosk_id: z.string().nullable(),
  language: z.string().min(2).max(35),
  symptoms: z.array(z.string().max(100)).max(100),
  free_text_summary: z.string().max(4000),
  patient_language_summary: z.string().max(4000),
  risk_score: z.number().int().min(0).max(100),
  risk_band: z.enum(["low", "medium", "high"]),
  recommended_specialty: z.string().min(1).max(120),
  letter_scan: z.object({ present: z.boolean(), extracted_text: z.string().max(10000).nullable() }).strict(),
  lesion_photo: z.object({ present: z.boolean(), assessment: z.string().max(10000).nullable() }).strict(),
  signature_template_encrypted: base64.min(40),
  triage_detail_encrypted: base64.min(40),
  salt: base64.refine(value => Buffer.from(value, "base64").length === 16, "Salt must contain 16 bytes"),
  commitment_hash: z.string().regex(/^[a-f0-9]{64}$/),
  status: z.enum(["open", "spent", "expired"]),
  expires_at: z.string().datetime(),
}).strict().refine(value => Date.parse(value.expires_at) > Date.parse(value.created_at), "Expiry must follow creation");

export type ReferralRecord = z.infer<typeof referralSchema>;
export type ReferralStatus = ReferralRecord["status"];
export type RiskBand = ReferralRecord["risk_band"];
export interface StatusEvent { status: ReferralStatus; at: string }
export type CRMReferral = Pick<ReferralRecord,
  "referral_id" | "created_at" | "language" | "symptoms" | "free_text_summary" |
  "patient_language_summary" | "risk_score" | "risk_band" | "recommended_specialty" |
  "letter_scan" | "lesion_photo" | "status" | "expires_at"
> & { status_history: StatusEvent[] };

// An allowlist prevents newly added private fields leaking through a spread.
export function toCRMReferral(record: ReferralRecord, history: StatusEvent[] = []): CRMReferral {
  return {
    referral_id: record.referral_id, created_at: record.created_at, language: record.language,
    symptoms: record.symptoms, free_text_summary: record.free_text_summary,
    patient_language_summary: record.patient_language_summary, risk_score: record.risk_score,
    risk_band: record.risk_band, recommended_specialty: record.recommended_specialty,
    letter_scan: record.letter_scan, lesion_photo: record.lesion_photo,
    status: record.status, expires_at: record.expires_at, status_history: history,
  };
}

export interface ReferralRepository {
  create(record: ReferralRecord): { created: boolean };
  list(): CRMReferral[];
  get(id: string): CRMReferral | undefined;
  verificationEnvelope(id: string): ReferralRecord | undefined;
}
export interface CommitmentAccount { commitment_hash: string; spent: boolean; created_slot: number; spent_slot: number | null }
export interface ChainClient {
  create(id: string, hash: string): void;
  read(id: string): CommitmentAccount | undefined;
  spend(id: string): void;
}


export const clinicalProfileSchema = z.object({
  concern_english: z.string().max(4000),
  symptoms_english: z.array(z.string().max(200)).max(30),
  duration_english: z.string().max(500),
  additional_context_english: z.string().max(4000),
}).strict();
export const conversationMessageSchema = z.object({ role: z.enum(["user", "assistant"]), text: z.string().min(1).max(4000) }).strict();
export const voiceTurnRequestSchema = z.object({
  consent: z.literal(true),
  audio_base64: base64.max(8 * 1024 * 1024).optional(),
  audio_mime_type: z.enum(["audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac", "audio/wav", "audio/mpeg", "audio/webm"]).optional(),
  text: z.string().trim().min(1).max(4000).optional(),
  language: z.string().regex(/^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/).optional(),
  profile: clinicalProfileSchema.optional(),
  history: z.array(conversationMessageSchema).max(30).optional(),
}).strict().refine(value => Boolean(value.audio_base64) !== Boolean(value.text), "Provide exactly one audio or text turn")
  .refine(value => !value.audio_base64 || Boolean(value.audio_mime_type), "Audio MIME type is required");
export type ClinicalProfile = z.infer<typeof clinicalProfileSchema>;
export type VoiceTurnRequest = z.infer<typeof voiceTurnRequestSchema>;
export interface VoiceTurnResponse {
  /** All essential intake answers collected; explicit patient uncertainty counts. */
  intake_complete: boolean;
  /** Stop listening after completion or an explicit patient request to stop. */
  conversation_ended: boolean;
  transcript: string;
  detected_language: string;
  reply: string;
  profile: ClinicalProfile;
  audio_base64: string | null;
  audio_mime_type: "audio/mpeg" | null;
  speech_available: boolean;
  speech_error: string | null;
}
