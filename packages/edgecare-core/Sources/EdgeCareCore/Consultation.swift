import Foundation

// Wire models mirror `consultationSchema` in packages/shared-types. Nullable keys are always
// encoded (as JSON null) because the server schema requires them to be present.

public enum ConsultationSpeaker: String, Codable, Sendable { case doctor, patient }

public struct ConsultationSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { seq }
    public let seq: Int
    public var speaker: ConsultationSpeaker
    public var sourceLanguage: String
    public var targetLanguage: String
    public var originalText: String
    public var translatedText: String
    public var speakerOverridden: Bool
    public var flagged: Bool
    public var correction: String?
    public init(seq: Int, speaker: ConsultationSpeaker, sourceLanguage: String, targetLanguage: String, originalText: String,
                translatedText: String = "", speakerOverridden: Bool = false, flagged: Bool = false, correction: String? = nil) {
        self.seq = seq; self.speaker = speaker; self.sourceLanguage = sourceLanguage; self.targetLanguage = targetLanguage
        self.originalText = originalText; self.translatedText = translatedText; self.speakerOverridden = speakerOverridden
        self.flagged = flagged; self.correction = correction
    }
    /// The translation participants agreed on: a correction always overrides the machine output.
    public var effectiveTranslation: String { correction ?? translatedText }
    enum CodingKeys: String, CodingKey {
        case seq, speaker, flagged, correction
        case sourceLanguage = "source_language", targetLanguage = "target_language", originalText = "original_text"
        case translatedText = "translated_text", speakerOverridden = "speaker_overridden"
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seq, forKey: .seq); try c.encode(speaker, forKey: .speaker)
        try c.encode(sourceLanguage, forKey: .sourceLanguage); try c.encode(targetLanguage, forKey: .targetLanguage)
        try c.encode(originalText, forKey: .originalText); try c.encode(translatedText, forKey: .translatedText)
        try c.encode(speakerOverridden, forKey: .speakerOverridden); try c.encode(flagged, forKey: .flagged)
        try c.encode(correction, forKey: .correction)
    }
}

public struct ConsultationStructured: Codable, Equatable, Sendable {
    public var presentingComplaint = ""
    public var symptoms: [String] = []
    public var duration = ""
    public var relevantHistory = ""
    public var examinationFindings = ""
    public var clinicianAssessment = ""
    public var plan = ""
    public var followUp = ""
    public var medicationsMentioned: [String] = []
    public var safetyConcerns: [String] = []
    public var recommendedSpecialty: String?
    public init() {}
    enum CodingKeys: String, CodingKey {
        case symptoms, duration, plan
        case presentingComplaint = "presenting_complaint", relevantHistory = "relevant_history"
        case examinationFindings = "examination_findings", clinicianAssessment = "clinician_assessment"
        case followUp = "follow_up", medicationsMentioned = "medications_mentioned", safetyConcerns = "safety_concerns"
        case recommendedSpecialty = "recommended_specialty"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presentingComplaint = try c.decode(String.self, forKey: .presentingComplaint)
        symptoms = try c.decode([String].self, forKey: .symptoms)
        duration = try c.decode(String.self, forKey: .duration)
        relevantHistory = try c.decode(String.self, forKey: .relevantHistory)
        examinationFindings = try c.decode(String.self, forKey: .examinationFindings)
        clinicianAssessment = try c.decode(String.self, forKey: .clinicianAssessment)
        plan = try c.decode(String.self, forKey: .plan)
        followUp = try c.decode(String.self, forKey: .followUp)
        medicationsMentioned = try c.decode([String].self, forKey: .medicationsMentioned)
        safetyConcerns = try c.decode([String].self, forKey: .safetyConcerns)
        recommendedSpecialty = try c.decodeIfPresent(String.self, forKey: .recommendedSpecialty)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(presentingComplaint, forKey: .presentingComplaint); try c.encode(symptoms, forKey: .symptoms)
        try c.encode(duration, forKey: .duration); try c.encode(relevantHistory, forKey: .relevantHistory)
        try c.encode(examinationFindings, forKey: .examinationFindings); try c.encode(clinicianAssessment, forKey: .clinicianAssessment)
        try c.encode(plan, forKey: .plan); try c.encode(followUp, forKey: .followUp)
        try c.encode(medicationsMentioned, forKey: .medicationsMentioned); try c.encode(safetyConcerns, forKey: .safetyConcerns)
        // An empty specialty is "not named"; the server requires null rather than "".
        let specialty = recommendedSpecialty?.trimmingCharacters(in: .whitespacesAndNewlines)
        try c.encode(specialty?.isEmpty == false ? specialty : nil, forKey: .recommendedSpecialty)
    }
}

public struct ConsultationNotesDraft: Codable, Equatable, Sendable {
    public var structured: ConsultationStructured
    public var clinicalSummary: String
    public var patientLanguageSummary: String
    public var meetingNotes: String
    public var meetingNotesPatientLanguage: String
    public var discrepancies: [String]
    public init(structured: ConsultationStructured = ConsultationStructured(), clinicalSummary: String = "", patientLanguageSummary: String = "",
                meetingNotes: String = "", meetingNotesPatientLanguage: String = "", discrepancies: [String] = []) {
        self.structured = structured; self.clinicalSummary = clinicalSummary; self.patientLanguageSummary = patientLanguageSummary
        self.meetingNotes = meetingNotes; self.meetingNotesPatientLanguage = meetingNotesPatientLanguage; self.discrepancies = discrepancies
    }
    enum CodingKeys: String, CodingKey {
        case structured, discrepancies
        case clinicalSummary = "clinical_summary", patientLanguageSummary = "patient_language_summary"
        case meetingNotes = "meeting_notes", meetingNotesPatientLanguage = "meeting_notes_patient_language"
    }
}

/// Legacy slot from the removed independent audio recorder. The deployed schema still requires it,
/// so it is always sent empty: the summary is drafted from the transcript text alone.
public struct ConsultationRecording: Codable, Equatable, Sendable {
    public var provider = "gemini-live"
    public var model: String?
    public var transcriptAvailable: Bool
    public var discrepancies: [String]
    public init(model: String?, transcriptAvailable: Bool, discrepancies: [String]) {
        self.model = model; self.transcriptAvailable = transcriptAvailable; self.discrepancies = discrepancies
    }
    enum CodingKeys: String, CodingKey { case provider, model, discrepancies, transcriptAvailable = "transcript_available" }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider, forKey: .provider); try c.encode(model, forKey: .model)
        try c.encode(transcriptAvailable, forKey: .transcriptAvailable); try c.encode(discrepancies, forKey: .discrepancies)
    }
}

public struct ConsultationConfirmation: Codable, Equatable, Sendable {
    public let patientConfirmedAt: String
    public let doctorConfirmedAt: String
    public let disputedItems: [String]
    enum CodingKeys: String, CodingKey {
        case patientConfirmedAt = "patient_confirmed_at", doctorConfirmedAt = "doctor_confirmed_at", disputedItems = "disputed_items"
    }
}

public struct ConsultationRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String { consultationID }
    public let consultationID: String
    public let referralID: String
    public let startedAt: String
    public let endedAt: String
    public let doctorLanguage: String
    public let patientLanguage: String
    public let structured: ConsultationStructured
    public let clinicalSummary: String
    public let patientLanguageSummary: String
    public let meetingNotes: String
    public let meetingNotesPatientLanguage: String
    public let transcript: [ConsultationSegment]
    public let recording: ConsultationRecording
    public let confirmation: ConsultationConfirmation
    enum CodingKeys: String, CodingKey {
        case structured, transcript, recording, confirmation
        case consultationID = "consultation_id", referralID = "referral_id", startedAt = "started_at", endedAt = "ended_at"
        case doctorLanguage = "doctor_language", patientLanguage = "patient_language", clinicalSummary = "clinical_summary"
        case patientLanguageSummary = "patient_language_summary", meetingNotes = "meeting_notes"
        case meetingNotesPatientLanguage = "meeting_notes_patient_language"
    }
}

// MARK: - Requests and responses

public struct ConsultationSessionRequest: Encodable, Sendable {
    public let consent: Bool
    public let referralID: String
    public let doctorLanguage: String
    public let patientLanguage: String
    public init(consent: Bool, referralID: String, doctorLanguage: String, patientLanguage: String) {
        self.consent = consent; self.referralID = referralID; self.doctorLanguage = doctorLanguage; self.patientLanguage = patientLanguage
    }
    enum CodingKeys: String, CodingKey { case consent, referralID = "referral_id", doctorLanguage = "doctor_language", patientLanguage = "patient_language" }
}
public struct RealtimeEndpoint: Codable, Equatable, Sendable {
    public let token: String
    public let model: String
    public let url: String
    public init(token: String, model: String, url: String) { self.token = token; self.model = model; self.url = url }
}
public struct ConsultationSessionCredentials: Codable, Equatable, Sendable {
    public let scribe: RealtimeEndpoint
    public let expiresAt: String
    enum CodingKeys: String, CodingKey { case scribe, expiresAt = "expires_at" }
}
public struct ConsultationTranslateRequest: Encodable, Sendable {
    public let consent: Bool
    public let text: String
    public let sourceLanguage: String
    public let targetLanguage: String
    public let speaker: ConsultationSpeaker
    public let synthesize: Bool
    public init(consent: Bool, text: String, sourceLanguage: String, targetLanguage: String, speaker: ConsultationSpeaker, synthesize: Bool = true) {
        self.consent = consent; self.text = text; self.sourceLanguage = sourceLanguage; self.targetLanguage = targetLanguage
        self.speaker = speaker; self.synthesize = synthesize
    }
    enum CodingKeys: String, CodingKey { case consent, text, speaker, synthesize, sourceLanguage = "source_language", targetLanguage = "target_language" }
}
public struct ConsultationTranslation: Decodable, Sendable {
    public let translatedText: String
    public let sourceLanguage: String
    public let targetLanguage: String
    public let audioBase64: String?
    public let speechAvailable: Bool
    public let speechError: String?
    public var audio: Data? { audioBase64.flatMap { Data(base64Encoded: $0) } }
    enum CodingKeys: String, CodingKey {
        case translatedText = "translated_text", sourceLanguage = "source_language", targetLanguage = "target_language"
        case audioBase64 = "audio_base64", speechAvailable = "speech_available", speechError = "speech_error"
    }
}
public struct ConsultationSpeakRequest: Encodable, Sendable {
    public let consent: Bool
    public let text: String
    public let language: String
    public init(consent: Bool, text: String, language: String) { self.consent = consent; self.text = text; self.language = language }
}
public struct ConsultationSpeech: Decodable, Sendable {
    public let audioBase64: String?
    public let speechAvailable: Bool
    public let speechError: String?
    public var audio: Data? { audioBase64.flatMap { Data(base64Encoded: $0) } }
    enum CodingKeys: String, CodingKey { case audioBase64 = "audio_base64", speechAvailable = "speech_available", speechError = "speech_error" }
}
public struct ConsultationNotesRequest: Encodable, Sendable {
    public let consent: Bool
    public let doctorLanguage: String
    public let patientLanguage: String
    public let transcript: [ConsultationSegment]
    public let clinicianEdits: String?
    public init(consent: Bool, doctorLanguage: String, patientLanguage: String, transcript: [ConsultationSegment], clinicianEdits: String? = nil) {
        self.consent = consent; self.doctorLanguage = doctorLanguage; self.patientLanguage = patientLanguage; self.transcript = transcript
        self.clinicianEdits = clinicianEdits
    }
    enum CodingKeys: String, CodingKey {
        case consent, transcript, doctorLanguage = "doctor_language", patientLanguage = "patient_language"
        case liveTranscript = "live_transcript", liveKeyPoints = "live_key_points", clinicianEdits = "clinician_edits"
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(consent, forKey: .consent); try c.encode(doctorLanguage, forKey: .doctorLanguage)
        try c.encode(patientLanguage, forKey: .patientLanguage); try c.encode(transcript, forKey: .transcript)
        // The removed recorder's inputs, still required (empty) by the deployed schema.
        try c.encodeNil(forKey: .liveTranscript); try c.encode([String](), forKey: .liveKeyPoints)
        try c.encodeIfPresent(clinicianEdits, forKey: .clinicianEdits)
    }
}

// MARK: - Speaker direction

/// Decides who spoke from the detected language. Anything else is "unclear" and is never spoken aloud.
public struct SpeakerResolver: Equatable, Sendable {
    public enum Resolution: Equatable, Sendable {
        case resolved(speaker: ConsultationSpeaker, source: String, target: String)
        case unclear
    }
    public let doctorLanguage: String
    public let patientLanguage: String
    public init(doctorLanguage: String, patientLanguage: String) {
        self.doctorLanguage = Self.normalize(doctorLanguage); self.patientLanguage = Self.normalize(patientLanguage)
    }
    private static let aliases = ["eng": "en", "fin": "fi", "som": "so", "ara": "ar", "ukr": "uk", "nep": "ne", "npi": "ne", "kur": "ku", "fra": "fr", "deu": "de", "spa": "es", "swe": "sv", "fas": "fa", "zho": "zh", "jpn": "ja", "kor": "ko"]
    public static func normalize(_ code: String) -> String {
        let base = code.lowercased().split(separator: "-").first.map(String.init) ?? code.lowercased()
        return aliases[base] ?? base
    }
    public func resolve(languageCode: String?) -> Resolution {
        guard let languageCode, !languageCode.isEmpty else { return .unclear }
        let language = Self.normalize(languageCode)
        if language == patientLanguage { return direction(for: .patient) }
        if language == doctorLanguage { return direction(for: .doctor) }
        return .unclear
    }
    public func direction(for speaker: ConsultationSpeaker) -> Resolution {
        speaker == .doctor ? .resolved(speaker: .doctor, source: doctorLanguage, target: patientLanguage)
            : .resolved(speaker: .patient, source: patientLanguage, target: doctorLanguage)
    }
}

// MARK: - Review and dual confirmation

/// Both participants must confirm the same content. Any change after a confirmation clears both,
/// and the patient cannot confirm a patient-language summary that predates the clinician's edits.
public struct ConsultationReview: Equatable, Sendable {
    public private(set) var draft: ConsultationNotesDraft
    public private(set) var segments: [ConsultationSegment]
    public private(set) var disputedItems: [String]
    public private(set) var patientConfirmedAt: Date?
    public private(set) var doctorConfirmedAt: Date?
    /// True after a clinician edit until the bilingual summaries are regenerated.
    public private(set) var patientSummaryStale = false
    public let endedAt: Date
    public init(draft: ConsultationNotesDraft, segments: [ConsultationSegment], endedAt: Date, disputedItems: [String] = []) {
        self.draft = draft; self.segments = segments; self.endedAt = endedAt; self.disputedItems = disputedItems
    }
    public var canPatientConfirm: Bool { !patientSummaryStale && !draft.patientLanguageSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var canSubmit: Bool { patientConfirmedAt != nil && doctorConfirmedAt != nil && !patientSummaryStale }
    private mutating func invalidate() { patientConfirmedAt = nil; doctorConfirmedAt = nil }

    public mutating func editByClinician(_ updated: ConsultationNotesDraft) {
        guard updated != draft else { return }
        draft = updated; patientSummaryStale = true; invalidate()
    }
    public mutating func applyRegenerated(_ updated: ConsultationNotesDraft) {
        draft = updated; patientSummaryStale = false; invalidate()
    }
    public mutating func setFlag(seq: Int, flagged: Bool, correction: String?) {
        guard let index = segments.firstIndex(where: { $0.seq == seq }) else { return }
        let trimmed = correction?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed?.isEmpty == false ? trimmed : nil
        guard segments[index].flagged != flagged || segments[index].correction != normalized else { return }
        segments[index].flagged = flagged; segments[index].correction = normalized
        // A corrected translation can change the facts behind the summaries.
        if normalized != nil { patientSummaryStale = true }
        invalidate()
    }
    public mutating func dispute(_ item: String) {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !disputedItems.contains(trimmed) { disputedItems.append(trimmed) }
        invalidate()
    }
    public mutating func confirmPatient(at date: Date = Date()) throws {
        guard canPatientConfirm else { throw CoreError.conflict }
        patientConfirmedAt = max(date, endedAt)
    }
    public mutating func confirmDoctor(at date: Date = Date()) {
        doctorConfirmedAt = max(date, endedAt)
    }
    public func record(consultationID: String, referralID: String, startedAt: Date, doctorLanguage: String, patientLanguage: String) throws -> ConsultationRecord {
        guard canSubmit, let patient = patientConfirmedAt, let doctor = doctorConfirmedAt else { throw CoreError.consentRequired }
        return ConsultationRecord(
            consultationID: consultationID.lowercased(), referralID: referralID.lowercased(),
            startedAt: ConsultationClock.string(startedAt), endedAt: ConsultationClock.string(endedAt),
            doctorLanguage: doctorLanguage, patientLanguage: patientLanguage, structured: draft.structured,
            clinicalSummary: draft.clinicalSummary, patientLanguageSummary: draft.patientLanguageSummary,
            meetingNotes: draft.meetingNotes, meetingNotesPatientLanguage: draft.meetingNotesPatientLanguage,
            // The health record keeps the confirmed summary and key points only; the word-for-word
            // conversation stays on this screen for review and is never saved or uploaded.
            transcript: [], recording: ConsultationRecording(model: nil, transcriptAvailable: false, discrepancies: draft.discrepancies),
            confirmation: ConsultationConfirmation(patientConfirmedAt: ConsultationClock.string(patient), doctorConfirmedAt: ConsultationClock.string(doctor), disputedItems: disputedItems))
    }
}

public enum ConsultationClock {
    public static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

// MARK: - Durable submission queue

/// Confirmed consultations are written here (encrypted) before upload, so a dropped connection
/// after both confirmations never loses the agreed record.
public actor ConsultationOutbox {
    private let storage: LocalStorage
    private var records: [ConsultationRecord]
    public init(storeURL: URL, key: Data) throws {
        guard key.count == 32 else { throw CoreError.invalidConfiguration }
        storage = LocalStorage(url: storeURL, key: key)
        records = try storage.read([ConsultationRecord].self) ?? []
    }
    public func pending() -> [ConsultationRecord] { records }
    public func enqueue(_ record: ConsultationRecord) throws {
        if let existing = records.first(where: { $0.id == record.id }) {
            guard existing == record else { throw CoreError.conflict }; return
        }
        let updated = records + [record]; try storage.write(updated); records = updated
    }
    public func remove(id: String) throws {
        let updated = records.filter { $0.id != id }; try storage.write(updated); records = updated
    }
}
