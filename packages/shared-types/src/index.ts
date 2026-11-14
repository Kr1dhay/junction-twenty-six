import { z } from "zod";

const base64 = z.string().regex(/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/).min(4);
export const commitmentRequestSchema = z.object({ commitment_hash: z.string().regex(/^[a-f0-9]{64}$/) }).strict();
export const spendRequestSchema = commitmentRequestSchema.extend({ operation_id: z.string().uuid().optional() }).strict();
/** Research observation only. No diagnosis, cancer probability, or triage score. */
export const voiceResearchAssessmentSchema = z.object({
  outcome: z.enum(["flagged", "not_flagged", "inconclusive"]),
  assessed_at: z.string().datetime(),
  model_id: z.string().min(1).max(120),
  model_version: z.string().min(1).max(120),
  sample_duration_seconds: z.number().finite().min(2).max(12),
  research_only: z.literal(true),
}).strict();
export type VoiceResearchAssessment = z.infer<typeof voiceResearchAssessmentSchema>;
export const voiceResearchRequestSchema = z.object({
  consent: z.literal(true),
  task: z.literal("sustained_a"),
  capture_mode: z.literal("measurement"),
  audio_base64: base64.max(700 * 1024),
}).strict();
export type VoiceResearchRequest = z.infer<typeof voiceResearchRequestSchema>;
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
  voice_research: voiceResearchAssessmentSchema.optional(),
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
  "letter_scan" | "lesion_photo" | "voice_research" | "status" | "expires_at"
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
    ...(record.voice_research === undefined ? {} : { voice_research: record.voice_research }),
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

// ---------------------------------------------------------------------------
// Consultations: a translated, recorded doctor visit linked to one referral.
// Append-only; never overwrites the patient's original triage. No audio is stored.
// ---------------------------------------------------------------------------
const languageCode = z.string().regex(/^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/);
const shortText = z.string().max(4000);
const textList = z.array(z.string().max(500)).max(50);
export const consultationSpeakerSchema = z.enum(["doctor", "patient"]);
export const consultationSegmentSchema = z.object({
  seq: z.number().int().min(0).max(100000),
  speaker: consultationSpeakerSchema,
  source_language: languageCode,
  target_language: languageCode,
  original_text: z.string().min(1).max(4000),
  translated_text: z.string().max(4000),
  speaker_overridden: z.boolean(),
  flagged: z.boolean(),
  correction: z.string().max(4000).nullable(),
}).strict();
/** Fields the CRM already reasons about; everything else belongs in meeting notes. */
export const consultationStructuredSchema = z.object({
  presenting_complaint: shortText,
  symptoms: z.array(z.string().max(200)).max(50),
  duration: z.string().max(500),
  relevant_history: shortText,
  examination_findings: shortText,
  /** Only what the clinician stated aloud; never model-generated assessment. */
  clinician_assessment: shortText,
  plan: shortText,
  follow_up: shortText,
  medications_mentioned: textList,
  safety_concerns: textList,
  recommended_specialty: z.string().min(1).max(120).nullable(),
}).strict();
export const consultationNotesDraftSchema = z.object({
  structured: consultationStructuredSchema,
  clinical_summary: shortText,
  patient_language_summary: shortText,
  meeting_notes: z.string().max(20000),
  meeting_notes_patient_language: z.string().max(20000),
  discrepancies: textList,
}).strict();
export const consultationSchema = z.object({
  consultation_id: z.string().uuid().transform(value => value.toLowerCase()),
  referral_id: z.string().uuid().transform(value => value.toLowerCase()),
  started_at: z.string().datetime(),
  ended_at: z.string().datetime(),
  doctor_language: languageCode,
  patient_language: languageCode,
  structured: consultationStructuredSchema,
  clinical_summary: shortText,
  patient_language_summary: shortText,
  meeting_notes: z.string().max(20000),
  meeting_notes_patient_language: z.string().max(20000),
  transcript: z.array(consultationSegmentSchema).max(2000),
  /** Legacy slot from the removed Gemini Live recorder; new clients send it empty. */
  recording: z.object({
    provider: z.literal("gemini-live"),
    model: z.string().max(120).nullable(),
    transcript_available: z.boolean(),
    discrepancies: textList,
  }).strict(),
  confirmation: z.object({
    patient_confirmed_at: z.string().datetime(),
    doctor_confirmed_at: z.string().datetime(),
    disputed_items: textList,
  }).strict(),
}).strict()
  .refine(value => Date.parse(value.ended_at) >= Date.parse(value.started_at), "End must follow start")
  .refine(value => Date.parse(value.confirmation.patient_confirmed_at) >= Date.parse(value.ended_at)
    && Date.parse(value.confirmation.doctor_confirmed_at) >= Date.parse(value.ended_at), "Confirmations must follow the session");
export type ConsultationSegment = z.infer<typeof consultationSegmentSchema>;
export type ConsultationStructured = z.infer<typeof consultationStructuredSchema>;
export type ConsultationNotesDraft = z.infer<typeof consultationNotesDraftSchema>;
export type ConsultationRecord = z.infer<typeof consultationSchema>;
export type CRMConsultation = Pick<ConsultationRecord,
  "consultation_id" | "referral_id" | "started_at" | "ended_at" | "doctor_language" | "patient_language" |
  "structured" | "clinical_summary" | "patient_language_summary" | "meeting_notes" |
  "meeting_notes_patient_language" | "transcript" | "recording" | "confirmation">;
// Allowlist like toCRMReferral, so future private fields cannot leak through a spread.
export function toCRMConsultation(record: ConsultationRecord): CRMConsultation {
  return {
    consultation_id: record.consultation_id, referral_id: record.referral_id,
    started_at: record.started_at, ended_at: record.ended_at,
    doctor_language: record.doctor_language, patient_language: record.patient_language,
    structured: record.structured, clinical_summary: record.clinical_summary,
    patient_language_summary: record.patient_language_summary, meeting_notes: record.meeting_notes,
    meeting_notes_patient_language: record.meeting_notes_patient_language,
    transcript: record.transcript, recording: record.recording, confirmation: record.confirmation,
  };
}
export const consultationSessionRequestSchema = z.object({
  consent: z.literal(true),
  referral_id: z.string().uuid(),
  doctor_language: languageCode,
  patient_language: languageCode,
}).strict();
export interface ConsultationSessionResponse {
  scribe: { token: string; model: string; url: string };
  expires_at: string;
}
export const consultationTranslateRequestSchema = z.object({
  consent: z.literal(true),
  text: z.string().trim().min(1).max(4000),
  source_language: languageCode,
  target_language: languageCode,
  speaker: consultationSpeakerSchema,
  synthesize: z.boolean().default(true),
}).strict();
export interface ConsultationTranslateResponse {
  translated_text: string;
  source_language: string;
  target_language: string;
  audio_base64: string | null;
  audio_mime_type: "audio/mpeg" | null;
  speech_available: boolean;
  speech_error: string | null;
}
export const consultationNotesRequestSchema = z.object({
  consent: z.literal(true),
  doctor_language: languageCode,
  patient_language: languageCode,
  transcript: z.array(consultationSegmentSchema).min(1).max(2000),
  /** Accepted and ignored: older app builds still send the removed recorder's transcript. */
  live_transcript: z.string().max(200000).nullable().optional(),
  live_key_points: z.array(z.string().max(1000)).max(500).optional(),
  clinician_edits: z.string().max(4000).optional(),
}).strict();
export type ConsultationTranslateRequest = z.infer<typeof consultationTranslateRequestSchema>;
export type ConsultationNotesRequest = z.infer<typeof consultationNotesRequestSchema>;
export type ConsultationSessionRequest = z.infer<typeof consultationSessionRequestSchema>;
/** Reads confirmed text aloud (e.g. the patient-language summary) without translating it. */
export const consultationSpeakRequestSchema = z.object({
  consent: z.literal(true),
  text: z.string().trim().min(1).max(4000),
  language: languageCode,
}).strict();
export type ConsultationSpeakRequest = z.infer<typeof consultationSpeakRequestSchema>;
