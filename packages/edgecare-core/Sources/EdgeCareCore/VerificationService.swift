import Foundation
public struct VerificationService: Sendable {
    public let chain: any ChainClient
    public init(chain: any ChainClient) { self.chain = chain }
    /// Authentication is entirely local, using the enrolled template bytes for the commitment.
    /// It confirms that the signature and code belong to this referral. It deliberately does
    /// not consume the referral, and it still succeeds after single use so a clinician can
    /// re-authenticate the same patient for a new visit.
    public static func authenticate(record: ReferralRecord, passcode: String, strokes: [[SignaturePoint]], now: Date = Date(), allowExpiredForDeletion: Bool = false) throws -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = formatter.date(from: record.expiresAt) ?? ISO8601DateFormatter().date(from: record.expiresAt)
        guard let expiry, allowExpiredForDeletion || expiry > now else { throw CoreError.expired }
        guard let salt = Data(base64Encoded: record.salt), let encrypted = Data(base64Encoded: record.signatureTemplateEncrypted),
              let id = UUID(uuidString: record.id) else { throw CoreError.verificationFailed }
        let enrolledData: Data
        do { enrolledData = try CommitmentCrypto.decrypt(encrypted, passcode: passcode, salt: salt) }
        catch { throw CoreError.verificationFailed }
        let enrolled = try JSONDecoder().decode(SignatureTemplate.self, from: enrolledData)
        let fresh = try SignatureMatcher.extract(strokes)
        guard SignatureMatcher.similarity(enrolled, fresh) >= SignatureMatcher.threshold else { throw CoreError.verificationFailed }
        let hash = try CommitmentCrypto.commitment(template: enrolledData, passcode: passcode, referralID: id, salt: salt)
        guard record.commitmentHash == hash else { throw CoreError.verificationFailed }
        return hash
    }
    public func verifyAndSpend(record: ReferralRecord, passcode: String, strokes: [[SignaturePoint]], now: Date = Date()) async throws {
        let hash = try Self.authenticate(record: record, passcode: passcode, strokes: strokes, now: now)
        guard let account = try await chain.read(referralID: record.id), account.commitmentHash == hash else { throw CoreError.verificationFailed }
        guard !account.spent else { throw CoreError.alreadySpent }
        try await chain.spend(referralID: record.id, hash: hash, operationID: UUID().uuidString.lowercased())
    }
}
/// Proof that the patient was authenticated during this visit. Constructed only inside the
/// core module, held in view state, and never persisted: relaunching the app or leaving the
/// verification screen requires the signature and code again.
public struct PatientVerification: Sendable, Equatable {
    public let referralID: String
    public let commitmentHash: String
    public let verifiedAt: Date
    init(referralID: String, commitmentHash: String, verifiedAt: Date = Date()) {
        self.referralID = referralID; self.commitmentHash = commitmentHash; self.verifiedAt = verifiedAt
    }
}
/// A matched referral and its fresh, in-memory proof. Search never consumes a referral.
public struct VerifiedReferralMatch: Sendable, Identifiable {
    public var id: String { record.id }
    public let record: ReferralRecord
    public let verification: PatientVerification
    init(record: ReferralRecord, verification: PatientVerification) {
        self.record = record; self.verification = verification
    }
}
public struct ReferralSearchResult: Sendable {
    public let matches: [VerifiedReferralMatch]
    /// True for local mode, offline lookup, or transport fallback to the encrypted cache.
    public let searchedLocalOnly: Bool
}
public enum VerificationSettlement: String, Sendable { case localDemo, confirmed, provisional }
public struct VerificationOutcome: Sendable {
    public let settlement: VerificationSettlement
    public let message: String
    public init(settlement: VerificationSettlement, message: String) { self.settlement = settlement; self.message = message }
}
