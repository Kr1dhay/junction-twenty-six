import CryptoKit
import Foundation
import Security
public enum CommitmentCrypto {
    public static func validate(passcode: String) throws {
        guard passcode.utf8.count == 4, passcode.utf8.allSatisfy({ (48...57).contains($0) }) else { throw CoreError.invalidPasscode }
    }
    public static func randomSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CoreError.invalidSalt }
        return Data(bytes)
    }
    public static func commitment(template: Data, passcode: String, referralID: UUID, salt: Data) throws -> String {
        try validate(passcode: passcode)
        guard salt.count == 16 else { throw CoreError.invalidSalt }
        let preimage = Data(SHA256.hash(data: template)) + Data(passcode.utf8) + Data(referralID.uuidString.lowercased().utf8) + salt
        return SHA256.hash(data: preimage).map { String(format: "%02x", $0) }.joined()
    }
    private static func key(passcode: String, salt: Data) throws -> SymmetricKey {
        try validate(passcode: passcode)
        guard salt.count == 16 else { throw CoreError.invalidSalt }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(passcode.utf8)), salt: salt,
            info: Data("edgecare.referral.v1".utf8), outputByteCount: 32)
    }
    public static func encrypt(_ plaintext: Data, passcode: String, salt: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key(passcode: passcode, salt: salt))
        guard let combined = sealed.combined else { throw CoreError.verificationFailed }
        return combined
    }
    public static func decrypt(_ ciphertext: Data, passcode: String, salt: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key(passcode: passcode, salt: salt))
    }
    static func editingKey(passcode: String, salt: Data) throws -> Data {
        try key(passcode: passcode, salt: salt).withUnsafeBytes { Data($0) }
    }
    static func encryptUpdate(_ plaintext: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw CoreError.verificationFailed }
        guard let combined = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key)).combined else { throw CoreError.verificationFailed }
        return combined
    }
}
