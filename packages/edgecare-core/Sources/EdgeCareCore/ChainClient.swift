import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
public struct CommitmentAccount: Codable, Equatable, Sendable {
    public let commitmentHash: String
    public var spent: Bool
    public let createdSlot: UInt64
    public var spentSlot: UInt64?
    public init(commitmentHash: String, spent: Bool, createdSlot: UInt64, spentSlot: UInt64? = nil) {
        self.commitmentHash = commitmentHash; self.spent = spent; self.createdSlot = createdSlot; self.spentSlot = spentSlot
    }
    enum CodingKeys: String, CodingKey {
        case commitmentHash = "commitment_hash", spent, createdSlot = "created_slot", spentSlot = "spent_slot"
    }
}
public protocol ChainClient: Sendable {
    func create(referralID: String, hash: String) async throws
    func read(referralID: String) async throws -> CommitmentAccount?
    func spend(referralID: String) async throws
    /// A stable operation ID allows an accepted spend whose response was lost to be retried safely.
    func spend(referralID: String, hash: String, operationID: String) async throws
}
public extension ChainClient {
    func spend(referralID: String, hash: String, operationID: String) async throws {
        guard let account = try await read(referralID: referralID), account.commitmentHash == hash else { throw CoreError.verificationFailed }
        try await spend(referralID: referralID)
    }
}
// One actor per URL; separate devices have independent mock state. Use the HTTP demo for shared state.
public actor MockChainClient: ChainClient {
    private let storage: LocalStorage
    private var accounts: [String: CommitmentAccount]
    private var receipts: [String: String]
    private var deleted: Set<String> = []
    private struct State: Codable { var accounts: [String: CommitmentAccount]; var receipts: [String: String]; var deleted: Set<String>? = nil }
    public init(storeURL: URL) throws {
        storage = LocalStorage(url: storeURL, key: nil)
        if let saved = try? storage.read(State.self) { accounts = saved.accounts; receipts = saved.receipts; deleted = saved.deleted ?? [] }
        else if FileManager.default.fileExists(atPath: storeURL.path) {
            // Migration from the scaffold's hash-only dictionary; never contains health information.
            struct OldAccount: Decodable {
                let commitmentHash: String; let spent: Bool; let createdSlot: UInt64; let spentSlot: UInt64?
            }
            let old = try JSONDecoder().decode([String: OldAccount].self, from: Data(contentsOf: storeURL))
            accounts = old.mapValues { CommitmentAccount(commitmentHash: $0.commitmentHash, spent: $0.spent, createdSlot: $0.createdSlot, spentSlot: $0.spentSlot) }
            receipts = [:]
        } else { accounts = [:]; receipts = [:] }
    }
    private func save(_ updated: [String: CommitmentAccount], receipts updatedReceipts: [String: String]) throws {
        try storage.write(State(accounts: updated, receipts: updatedReceipts, deleted: deleted)); accounts = updated; receipts = updatedReceipts
    }
    public func create(referralID: String, hash: String) throws {
        try validateCommitment(referralID: referralID, hash: hash)
        guard !deleted.contains(referralID) else { throw CoreError.deleted }
        if let old = accounts[referralID] {
            guard old.commitmentHash == hash else { throw CoreError.conflict }; return
        }
        var updated = accounts
        updated[referralID] = CommitmentAccount(commitmentHash: hash, spent: false, createdSlot: UInt64(accounts.count + 1))
        try save(updated, receipts: receipts)
    }
    public func removeProfile(referralID: String) throws {
        var updated = accounts; updated.removeValue(forKey: referralID)
        var updatedReceipts = receipts; updatedReceipts.removeValue(forKey: referralID)
        let updatedDeleted = deleted.union([referralID])
        try storage.write(State(accounts: updated, receipts: updatedReceipts, deleted: updatedDeleted))
        accounts = updated; receipts = updatedReceipts; deleted = updatedDeleted
    }
    public func read(referralID: String) -> CommitmentAccount? { accounts[referralID] }
    public func spend(referralID: String) throws {
        guard let account = accounts[referralID] else { throw CoreError.notFound }
        try spend(referralID: referralID, hash: account.commitmentHash, operationID: UUID().uuidString.lowercased())
    }
    public func spend(referralID: String, hash: String, operationID: String) throws {
        guard UUID(uuidString: operationID) != nil else { throw CoreError.invalidConfiguration }
        guard var account = accounts[referralID] else { throw CoreError.notFound }
        guard account.commitmentHash == hash else { throw CoreError.conflict }
        if account.spent {
            guard receipts[referralID] == operationID else { throw CoreError.alreadySpent }; return
        }
        account.spent = true; account.spentSlot = account.createdSlot + 1
        var updated = accounts; updated[referralID] = account
        var updatedReceipts = receipts; updatedReceipts[referralID] = operationID
        try save(updated, receipts: updatedReceipts)
    }
}
func validateCommitment(referralID: String, hash: String) throws {
    guard let uuid = UUID(uuidString: referralID), uuid.uuidString.lowercased() == referralID,
          hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw CoreError.verificationFailed }
}

/// Explicit shared synthetic registry transport. It is not a Solana RPC or devnet adapter.
public struct HTTPDemoChainClient: ChainClient {
    private let transport: DemoHTTPTransport
    public init(baseURL: URL, configuration: AppConfiguration, bearerToken: String? = nil, issuerToken: String? = nil) {
        transport = DemoHTTPTransport(baseURL: baseURL, configuration: configuration, bearerToken: bearerToken, issuerToken: issuerToken)
    }
    public func create(referralID: String, hash: String) async throws {
        try validateCommitment(referralID: referralID, hash: hash)
        let body = try JSONEncoder().encode(CommitmentRequest(commitmentHash: hash, operationID: nil))
        _ = try await transport.request(path: ["demo", "commitments", referralID], method: "PUT", body: body, issuer: true)
    }
    public func read(referralID: String) async throws -> CommitmentAccount? {
        guard UUID(uuidString: referralID) != nil else { throw CoreError.notFound }
        do {
            let data = try await transport.request(path: ["demo", "commitments", referralID])
            return try JSONDecoder().decode(CommitmentAccount.self, from: data)
        } catch CoreError.notFound { return nil }
    }
    public func spend(referralID: String) async throws {
        guard let account = try await read(referralID: referralID) else { throw CoreError.notFound }
        try await spend(referralID: referralID, hash: account.commitmentHash, operationID: UUID().uuidString.lowercased())
    }
    public func spend(referralID: String, hash: String, operationID: String) async throws {
        try validateCommitment(referralID: referralID, hash: hash)
        guard UUID(uuidString: operationID) != nil else { throw CoreError.invalidConfiguration }
        let body = try JSONEncoder().encode(CommitmentRequest(commitmentHash: hash, operationID: operationID))
        _ = try await transport.request(path: ["demo", "commitments", referralID, "spend"], method: "POST", body: body)
    }
}
private struct CommitmentRequest: Encodable {
    let commitmentHash: String
    let operationID: String?
    enum CodingKeys: String, CodingKey { case commitmentHash = "commitment_hash", operationID = "operation_id" }
}
public struct DevnetChainClient: ChainClient {
    public init() {}
    public func create(referralID: String, hash: String) async throws { throw CoreError.notConfigured }
    public func read(referralID: String) async throws -> CommitmentAccount? { throw CoreError.notConfigured }
    public func spend(referralID: String) async throws { throw CoreError.notConfigured }
}
