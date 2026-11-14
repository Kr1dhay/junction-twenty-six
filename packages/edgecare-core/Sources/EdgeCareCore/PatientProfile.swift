import CryptoKit
import Foundation

/// Fresh patient login. Never Codable: neither the code, signature nor unlocked key is saved.
/// Only the ownership login below can construct this; clinician debug bypasses cannot.
public struct PatientProfileAccess: Sendable, Identifiable {
    public var id: String { record.id }
    public let record: ReferralRecord
    let key: Data
    let verifiedAt: Date
    init(record: ReferralRecord, passcode: String, strokes: [[SignaturePoint]], now: Date = Date()) throws {
        _ = try VerificationService.authenticate(record: record, passcode: passcode, strokes: strokes,
                                                 now: now, allowExpiredForDeletion: true)
        guard let salt = Data(base64Encoded: record.salt) else { throw CoreError.verificationFailed }
        self.record = record; key = try CommitmentCrypto.editingKey(passcode: passcode, salt: salt); verifiedAt = now
    }
}

func validateDeletionKey(record: ReferralRecord, key: Data) throws {
    guard key.count == 32, let encrypted = Data(base64Encoded: record.triageDetailEncrypted) else { throw CoreError.verificationFailed }
    _ = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: SymmetricKey(data: key))
}
