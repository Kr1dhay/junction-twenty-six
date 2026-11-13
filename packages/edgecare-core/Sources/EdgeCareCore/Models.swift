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
public enum CoreError: Error, Equatable { case invalidPasscode, invalidSalt, invalidSignature, notConfigured, conflict, notFound, alreadySpent, expired, verificationFailed, invalidConfiguration }
