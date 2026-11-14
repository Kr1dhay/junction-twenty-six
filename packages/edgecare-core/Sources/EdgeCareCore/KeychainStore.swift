import Foundation
import Security
import CryptoKit

/// Local wallet keys only. Never retain the patient's four-digit passcode.
public struct KeychainStore: Sendable {
    private let service: String
    public init(service: String = "org.edgecare.local-keys") { self.service = service }
    public func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CoreError.notConfigured }
        } else if result != errSecSuccess { throw CoreError.notConfigured }
    }
    public func read(account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CoreError.notConfigured }
        return result as? Data
    }
    public func delete(account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CoreError.notConfigured }
    }
}

extension KeychainStore {
    public func walletKey(account: String = "referral-wallet-v1", authenticating encryptedFiles: [Data] = []) throws -> Data {
        if let existing = try read(account: account) {
            guard existing.count == 32 else { throw CoreError.invalidConfiguration }
            return existing
        }
        let key: Data
        if !encryptedFiles.isEmpty {
            // Older app versions hashed the absolute sandbox path into the key
            // account. Reinstalling can move that path while retaining the data.
            // Recover only a key that authenticates every existing cache file.
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecReturnData as String: true,
                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CoreError.notConfigured }
            let candidates = (result as? [[String: Any]] ?? []).compactMap { item -> Data? in
                guard let name = item[kSecAttrAccount as String] as? String,
                      name.hasPrefix("wallet-v1-") else { return nil }
                return item[kSecValueData as String] as? Data
            }
            guard let recovered = Self.matchingWalletKey(encryptedFiles: encryptedFiles, candidates: candidates) else {
                // Never replace a missing key with a random key over existing data.
                throw CryptoKitError.authenticationFailure
            }
            key = recovered
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CoreError.notConfigured }
            key = Data(bytes)
        }
        // Add rather than update: concurrent session startup must not replace an existing wallet key.
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecValueData as String: key, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try read(account: account), existing.count == 32 { return existing }
        guard status == errSecSuccess else { throw CoreError.notConfigured }
        return key
    }

    static func matchingWalletKey(encryptedFiles: [Data], candidates: [Data]) -> Data? {
        guard !encryptedFiles.isEmpty else { return nil }
        return candidates.first { key in
            key.count == 32 && encryptedFiles.allSatisfy { data in
                guard let box = try? AES.GCM.SealedBox(combined: data) else { return false }
                return (try? AES.GCM.open(box, using: SymmetricKey(data: key))) != nil
            }
        }
    }
}
