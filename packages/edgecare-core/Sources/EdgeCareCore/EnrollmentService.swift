import Foundation

public struct EnrollmentDraft: Sendable {
    public let source: ReferralSource
    public let language: String
    public let concern: String
    public let guidance: TriageGuidance
    public let letterText: String?
    public let lesionPresent: Bool
    public let answers: [String: String]
    public let clinicalProfile: ClinicalProfile?
    public init(source: ReferralSource, language: String, concern: String, guidance: TriageGuidance,
                letterText: String? = nil, lesionPresent: Bool = false, answers: [String: String] = [:], clinicalProfile: ClinicalProfile? = nil) {
        self.source = source; self.language = language; self.concern = concern; self.guidance = guidance
        self.letterText = letterText; self.lesionPresent = lesionPresent; self.answers = answers; self.clinicalProfile = clinicalProfile
    }
}

public struct EnrollmentService: Sendable {
    public init() {}
    /// No passcode, raw signature or conversation survives outside the encrypted fields.
    public func enroll(draft: EnrollmentDraft, strokes: [[SignaturePoint]], passcode: String,
                       confirmation: String, now: Date = Date(), referralID: UUID = UUID()) throws -> ReferralRecord {
        try CommitmentCrypto.validate(passcode: passcode)
        try CommitmentCrypto.validate(passcode: confirmation)
        guard passcode == confirmation else { throw CoreError.passcodesDoNotMatch }
        guard !draft.concern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoreError.emptyConcern }
        let template = try SignatureMatcher.extract(strokes).canonicalData()
        let salt = try CommitmentCrypto.randomSalt()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let privateDetail = try encoder.encode(PrivateTriageDetail(concern: draft.concern, answers: draft.answers, letterText: draft.letterText, clinicalProfile: draft.clinicalProfile))
        let signature = try CommitmentCrypto.encrypt(template, passcode: passcode, salt: salt)
        let triage = try CommitmentCrypto.encrypt(privateDetail, passcode: passcode, salt: salt)
        let proposedLanguage = draft.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let language = proposedLanguage.range(of: "^[a-z]{2,3}(-[a-z0-9]{2,8})*$", options: .regularExpression) != nil && proposedLanguage.count <= 35 ? proposedLanguage : "en"
        // Keep the clinician-facing description free of demo disclaimers; those stay in the UI.
        let englishSummary = [draft.clinicalProfile?.clinicianSummary, draft.guidance.clinicianSummary]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: "") { result, part in
                if !result.isEmpty { result += result.hasSuffix(".") ? " " : ". " }
                result += part
            }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ReferralRecord(referralID: referralID.uuidString.lowercased(), createdAt: formatter.string(from: now),
            source: draft.source, kioskID: nil, language: language,
            symptoms: draft.guidance.symptoms, freeTextSummary: String(englishSummary.prefix(4000)),
            patientLanguageSummary: draft.guidance.message, riskScore: draft.guidance.riskScore,
            riskBand: draft.guidance.riskBand, recommendedSpecialty: draft.guidance.recommendedSpecialty,
            letterScan: LetterScan(present: draft.letterText != nil, extractedText: nil),
            lesionPhoto: LesionPhoto(present: draft.lesionPresent, assessment: draft.lesionPresent ? "Photo capture noted. Raw image is not retained and no medical image assessment was performed." : nil),
            signatureTemplateEncrypted: signature.base64EncodedString(), triageDetailEncrypted: triage.base64EncodedString(),
            salt: salt.base64EncodedString(), commitmentHash: try CommitmentCrypto.commitment(template: template, passcode: passcode, referralID: referralID, salt: salt),
            status: .open, expiresAt: formatter.string(from: now.addingTimeInterval(30 * 24 * 60 * 60)))
    }
}
private struct PrivateTriageDetail: Codable {
    let concern: String
    let answers: [String: String]
    let letterText: String?
    let clinicalProfile: ClinicalProfile?
}
