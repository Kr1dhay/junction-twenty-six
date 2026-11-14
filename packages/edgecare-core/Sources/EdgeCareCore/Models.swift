import Foundation
public enum ReferralSource: String, Codable, Sendable { case kiosk; case patientApp = "patient_app" }
public enum ReferralStatus: String, Codable, Sendable { case open, spent, expired }
public enum RiskBand: String, Codable, Sendable { case low, medium, high }
public struct LetterScan: Codable, Equatable, Sendable {
    public let present: Bool
    public let extractedText: String?
    public init(present: Bool, extractedText: String?) { self.present = present; self.extractedText = extractedText }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(present, forKey: .present)
        try container.encode(extractedText, forKey: .extractedText)
    }
    enum CodingKeys: String, CodingKey { case present; case extractedText = "extracted_text" }
}
public struct LesionPhoto: Codable, Equatable, Sendable {
    public let present: Bool
    public let assessment: String?
    public init(present: Bool, assessment: String?) { self.present = present; self.assessment = assessment }
    enum CodingKeys: String, CodingKey { case present, assessment }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(present, forKey: .present)
        try container.encode(assessment, forKey: .assessment)
    }
}
public struct ReferralRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String { referralID }
    public let referralID: String
    public let createdAt: String
    public let source: ReferralSource
    public let kioskID: String?
    public let language: String
    public let symptoms: [String]
    public let freeTextSummary: String
    public let patientLanguageSummary: String
    public let riskScore: Int
    public let riskBand: RiskBand
    public let recommendedSpecialty: String
    public let letterScan: LetterScan
    public let lesionPhoto: LesionPhoto
    public let signatureTemplateEncrypted: String
    public let triageDetailEncrypted: String
    public let salt: String
    public let commitmentHash: String
    public let status: ReferralStatus
    public let expiresAt: String
    public init(referralID: String, createdAt: String, source: ReferralSource, kioskID: String?, language: String, symptoms: [String], freeTextSummary: String, patientLanguageSummary: String, riskScore: Int, riskBand: RiskBand, recommendedSpecialty: String, letterScan: LetterScan, lesionPhoto: LesionPhoto, signatureTemplateEncrypted: String, triageDetailEncrypted: String, salt: String, commitmentHash: String, status: ReferralStatus, expiresAt: String) {
        self.referralID = referralID
        self.createdAt = createdAt
        self.source = source
        self.kioskID = kioskID
        self.language = language
        self.symptoms = symptoms
        self.freeTextSummary = freeTextSummary
        self.patientLanguageSummary = patientLanguageSummary
        self.riskScore = riskScore
        self.riskBand = riskBand
        self.recommendedSpecialty = recommendedSpecialty
        self.letterScan = letterScan
        self.lesionPhoto = lesionPhoto
        self.signatureTemplateEncrypted = signatureTemplateEncrypted
        self.triageDetailEncrypted = triageDetailEncrypted
        self.salt = salt
        self.commitmentHash = commitmentHash
        self.status = status
        self.expiresAt = expiresAt
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(referralID, forKey: .referralID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(source, forKey: .source)
        try container.encode(kioskID, forKey: .kioskID)
        try container.encode(language, forKey: .language)
        try container.encode(symptoms, forKey: .symptoms)
        try container.encode(freeTextSummary, forKey: .freeTextSummary)
        try container.encode(patientLanguageSummary, forKey: .patientLanguageSummary)
        try container.encode(riskScore, forKey: .riskScore)
        try container.encode(riskBand, forKey: .riskBand)
        try container.encode(recommendedSpecialty, forKey: .recommendedSpecialty)
        try container.encode(letterScan, forKey: .letterScan)
        try container.encode(lesionPhoto, forKey: .lesionPhoto)
        try container.encode(signatureTemplateEncrypted, forKey: .signatureTemplateEncrypted)
        try container.encode(triageDetailEncrypted, forKey: .triageDetailEncrypted)
        try container.encode(salt, forKey: .salt)
        try container.encode(commitmentHash, forKey: .commitmentHash)
        try container.encode(status, forKey: .status)
        try container.encode(expiresAt, forKey: .expiresAt)
    }
    enum CodingKeys: String, CodingKey {
        case referralID = "referral_id"
        case createdAt = "created_at"
        case source = "source"
        case kioskID = "kiosk_id"
        case language = "language"
        case symptoms = "symptoms"
        case freeTextSummary = "free_text_summary"
        case patientLanguageSummary = "patient_language_summary"
        case riskScore = "risk_score"
        case riskBand = "risk_band"
        case recommendedSpecialty = "recommended_specialty"
        case letterScan = "letter_scan"
        case lesionPhoto = "lesion_photo"
        case signatureTemplateEncrypted = "signature_template_encrypted"
        case triageDetailEncrypted = "triage_detail_encrypted"
        case salt = "salt"
        case commitmentHash = "commitment_hash"
        case status = "status"
        case expiresAt = "expires_at"
    }
}
public enum DemoData {
    public static func referrals() throws -> [ReferralRecord] {
        guard let url = Bundle.module.url(forResource: "referrals", withExtension: "json") else { throw CoreError.notConfigured }
        return try JSONDecoder().decode([ReferralRecord].self, from: Data(contentsOf: url))
    }
}
public enum CoreError: Error, Equatable { case invalidPasscode, invalidSalt, invalidSignature, notConfigured, conflict, notFound, alreadySpent, expired, verificationFailed, invalidConfiguration, passcodesDoNotMatch, emptyConcern, offline, noCachedCommitment, consentRequired, invalidResponse, unauthorized, providerUnavailable, languageUncertain }

public extension ReferralRecord {
    /// Clinician-facing description. Older records stored the scripted-demo disclaimers inside
    /// `free_text_summary`; strip that boilerplate at presentation time. Disclaimers belong in
    /// the UI, not in the patient's referral description.
    var clinicalDescription: String {
        let boilerplate = [
            "Scripted demo intake: ",
            "Scripted demo flagged possible emergency words. ",
            " Demo priority is not a validated medical score.",
            "Demo priority is not a validated medical score."
        ]
        var text = freeTextSummary
        for phrase in boilerplate { text = text.replacingOccurrences(of: phrase, with: "") }
        while text.contains(".. ") { text = text.replacingOccurrences(of: ".. ", with: ". ") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public extension DemoData {
    static let passcode = "1234"
    static func signatureStrokes() -> [[SignaturePoint]] {
        [(0..<8).map { SignaturePoint(x: Double($0), y: Double($0)) }]
    }
}

public extension CoreError {
    var userMessage: String {
        switch self {
        case .invalidPasscode: return "Enter exactly four digits (0–9)."
        case .passcodesDoNotMatch: return "The two passcodes differ. Please enter them again."
        case .invalidSignature: return "Please draw a longer signature and try again."
        case .emptyConcern: return "Please describe your concern first."
        case .alreadySpent: return "This referral has already been used. Ask the clinician for help."
        case .expired: return "This referral has expired. Please ask for a new assessment."
        case .offline, .noCachedCommitment: return "This device needs to load the referral and its commitment while connected before it can verify offline."
        case .verificationFailed: return "We could not match this signature and passcode. Please try again."
        case .conflict: return "Another verification was accepted first. Clinician review is needed."
        case .notFound: return "This referral was not found on this device or service."
        case .consentRequired: return "Online processing needs explicit consent. You can continue on this device."
        case .languageUncertain: return "The spoken language could not be detected confidently. Please repeat or choose your language."
        case .providerUnavailable: return "Online voice is not configured or is temporarily unavailable. Continue with the form on this device."
        case .unauthorized: return "This service needs a configured clinician or issuer access token."
        default: return "This action could not complete. Your saved referral remains on this device."
        }
    }
}
