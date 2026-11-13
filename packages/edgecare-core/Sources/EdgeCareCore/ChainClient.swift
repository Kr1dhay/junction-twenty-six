import Foundation
public struct CommitmentAccount: Codable, Equatable, Sendable {
    public let commitmentHash: String
    public var spent: Bool
    public let createdSlot: UInt64
    public var spentSlot: UInt64?
}
public protocol ChainClient: Sendable {
    func create(referralID: String, hash: String) async throws
    func read(referralID: String) async throws -> CommitmentAccount?
    func spend(referralID: String) async throws
}
// One actor per URL; separate devices have independent mock state.
public actor MockChainClient: ChainClient {
    private let url: URL
    private var accounts: [String: CommitmentAccount]
    public init(storeURL: URL) throws {
        url = storeURL
        accounts = FileManager.default.fileExists(atPath: storeURL.path)
            ? try JSONDecoder().decode([String: CommitmentAccount].self, from: Data(contentsOf: storeURL)) : [:]
    }
    private func save(_ updated: [String: CommitmentAccount]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        accounts = updated
    }
    public func create(referralID: String, hash: String) throws {
        guard UUID(uuidString: referralID) != nil, hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw CoreError.verificationFailed }
        if let old = accounts[referralID] {
            guard old.commitmentHash == hash else { throw CoreError.conflict }; return
        }
        var updated = accounts
        updated[referralID] = CommitmentAccount(commitmentHash: hash, spent: false, createdSlot: UInt64(accounts.count + 1), spentSlot: nil)
        try save(updated)
    }
    public func read(referralID: String) -> CommitmentAccount? { accounts[referralID] }
    public func spend(referralID: String) throws {
        guard var account = accounts[referralID] else { throw CoreError.notFound }
        guard !account.spent else { throw CoreError.alreadySpent }
        account.spent = true; account.spentSlot = account.createdSlot + 1
        var updated = accounts; updated[referralID] = account; try save(updated)
    }
}
public struct DevnetChainClient: ChainClient {
    public init() {}
    public func create(referralID: String, hash: String) async throws { throw CoreError.notConfigured }
    public func read(referralID: String) async throws -> CommitmentAccount? { throw CoreError.notConfigured }
    public func spend(referralID: String) async throws { throw CoreError.notConfigured }
}
