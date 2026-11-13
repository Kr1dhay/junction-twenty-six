import Foundation
public struct VerificationService: Sendable {
    public let chain: any ChainClient
    public init(chain: any ChainClient) { self.chain = chain }
    public func verifyAndSpend(record: ReferralRecord, passcode: String, strokes: [[SignaturePoint]], now: Date = Date()) async throws {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = formatter.date(from: record.expiresAt) ?? ISO8601DateFormatter().date(from: record.expiresAt)
        guard let expiry, expiry > now else { throw CoreError.expired }
        guard record.status == .open else { throw CoreError.verificationFailed }
        guard let salt = Data(base64Encoded: record.salt), let encrypted = Data(base64Encoded: record.signatureTemplateEncrypted),
              let id = UUID(uuidString: record.id) else { throw CoreError.verificationFailed }
        let enrolledData = try CommitmentCrypto.decrypt(encrypted, passcode: passcode, salt: salt)
        let enrolled = try JSONDecoder().decode(SignatureTemplate.self, from: enrolledData)
        let fresh = try SignatureMatcher.extract(strokes)
        guard SignatureMatcher.similarity(enrolled, fresh) >= SignatureMatcher.threshold else { throw CoreError.verificationFailed }
        let hash = try CommitmentCrypto.commitment(template: enrolledData, passcode: passcode, referralID: id, salt: salt)
        guard let account = try await chain.read(referralID: record.id), account.commitmentHash == hash,
              record.commitmentHash == hash else { throw CoreError.verificationFailed }
        guard !account.spent else { throw CoreError.alreadySpent }
        try await chain.spend(referralID: record.id)
    }
}
