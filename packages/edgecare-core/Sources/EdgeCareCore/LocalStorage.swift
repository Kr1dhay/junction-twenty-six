import CryptoKit
import Foundation

/// AES-GCM device storage. The random key is stored separately in the device Keychain.
struct LocalStorage: Sendable {
    let url: URL
    let key: Data?
    func read<Value: Decodable>(_ type: Value.Type) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stored = try Data(contentsOf: url)
        let plaintext: Data
        if let key {
            guard key.count == 32 else { throw CoreError.invalidConfiguration }
            plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: stored), using: SymmetricKey(data: key))
        } else { plaintext = stored }
        return try JSONDecoder().decode(type, from: plaintext)
    }
    func write<Value: Encodable>(_ value: Value) throws {
        let plaintext = try JSONEncoder().encode(value)
        let stored: Data
        if let key {
            guard key.count == 32 else { throw CoreError.invalidConfiguration }
            guard let combined = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key)).combined else { throw CoreError.verificationFailed }
            stored = combined
        } else { stored = plaintext }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try stored.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try stored.write(to: url, options: .atomic)
        #endif
    }
}

public enum WalletState: String, Codable, Sendable {
    case pendingEnrollment, available, provisionalSpend, spent, conflict
}
public struct WalletEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String { record.id }
    public let record: ReferralRecord
    public var state: WalletState
    public var cachedAccount: CommitmentAccount?
    public init(record: ReferralRecord, state: WalletState = .available, cachedAccount: CommitmentAccount? = nil) {
        self.record = record; self.state = state; self.cachedAccount = cachedAccount
    }
}
/// Contains no plaintext file: even clinician summaries are encrypted with the Keychain-backed key.
public actor ReferralWallet {
    private let storage: LocalStorage
    private var entries: [WalletEntry]
    private var blocked: Set<String>
    private struct State: Codable { let entries: [WalletEntry]; let blocked: Set<String> }
    private func hash(_ id: String) -> String { SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() }
    public func deletionRequested(id: String) -> Bool { blocked.contains(hash(id)) }
    public func beginDeletion(id: String) throws {
        let updated = blocked.union([hash(id)])
        try storage.write(State(entries: entries, blocked: updated)); blocked = updated
    }
    private func save(_ updated: [WalletEntry]) throws {
        try storage.write(State(entries: updated, blocked: blocked)); entries = updated
    }
    public init(storeURL: URL, key: Data) throws {
        guard key.count == 32 else { throw CoreError.invalidConfiguration }
        storage = LocalStorage(url: storeURL, key: key)
        if let current = try? storage.read(State.self) { entries = current.entries; blocked = current.blocked }
        else { entries = try storage.read([WalletEntry].self) ?? []; blocked = [] }
    }
    public func records() -> [ReferralRecord] { entries.map(\.record) }
    public func allEntries() -> [WalletEntry] { entries.sorted { $0.record.createdAt > $1.record.createdAt } }
    public func entry(id: String) -> WalletEntry? { entries.first { $0.id == id } }
    public func store(_ record: ReferralRecord, state: WalletState = .available, account: CommitmentAccount? = nil) throws {
        guard !deletionRequested(id: record.id) else { throw CoreError.notFound }
        var updated = entries
        if let index = updated.firstIndex(where: { $0.id == record.id }) {
            guard updated[index].record.commitmentHash == record.commitmentHash else { throw CoreError.conflict }
            // Refetching an open server envelope must never reopen a locally spent/provisional referral.
            let old = updated[index]
            let retainedState = [.spent, .provisionalSpend, .conflict].contains(old.state) ? old.state : state
            updated[index] = WalletEntry(record: record, state: retainedState, cachedAccount: account ?? old.cachedAccount)
        } else { updated.append(WalletEntry(record: record, state: state, cachedAccount: account)) }
        try save(updated)
    }
    public func update(id: String, state: WalletState, account: CommitmentAccount? = nil) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw CoreError.notFound }
        var updated = entries; updated[index].state = state
        if let account { updated[index].cachedAccount = account }
        try save(updated)
    }
    /// Atomically refreshes an available entry; remote reads cannot overwrite a pending spend or conflict.
    func reconcile(account: CommitmentAccount, id: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[index].record.commitmentHash == account.commitmentHash else { throw CoreError.verificationFailed }
        guard entries[index].state == .available else { return }
        var updated = entries
        updated[index].cachedAccount = account
        if account.spent { updated[index].state = .spent }
        try save(updated)
    }
    public func remove(id: String) throws {
        let updated = entries.filter { $0.id != id }; try save(updated)
    }
}
