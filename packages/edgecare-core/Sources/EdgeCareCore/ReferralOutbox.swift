import Foundation

public struct PendingSpend: Codable, Equatable, Sendable, Identifiable {
    public var id: String { operationID }
    public let operationID: String
    public let referralID: String
    public let commitmentHash: String
    public init(referralID: String, commitmentHash: String, operationID: String = UUID().uuidString.lowercased()) {
        self.referralID = referralID; self.commitmentHash = commitmentHash; self.operationID = operationID
    }
}
public struct SyncReport: Sendable {
    public let uploaded: Int
    public let confirmedSpends: Int
    public let conflicts: [String]
    public init(uploaded: Int = 0, confirmedSpends: Int = 0, conflicts: [String] = []) {
        self.uploaded = uploaded; self.confirmedSpends = confirmedSpends; self.conflicts = conflicts
    }
}
/// Durable enrollment and spend operations; NativeSession supplies its Keychain storage key.
public actor ReferralOutbox {
    private struct SpendReceipt: Codable { let referralID: String; let conflict: Bool }
    private struct State: Codable {
        var records: [ReferralRecord] = []
        var spends: [PendingSpend] = []
        var receipts: [SpendReceipt] = []
    }
    private let storage: LocalStorage
    private var state: State
    private var syncing = false
    public init(storeURL: URL, key: Data? = nil) throws {
        storage = LocalStorage(url: storeURL, key: key)
        if let current = try? storage.read(State.self) { state = current }
        else if FileManager.default.fileExists(atPath: storeURL.path), key == nil {
            state = State(records: try JSONDecoder().decode([ReferralRecord].self, from: Data(contentsOf: storeURL)))
        } else { state = try storage.read(State.self) ?? State() }
    }
    public func pending() -> [ReferralRecord] { state.records }
    public func pendingSpends() -> [PendingSpend] { state.spends }
    private func save(_ updated: State) throws { try storage.write(updated); state = updated }
    public func enqueue(_ record: ReferralRecord) throws {
        if let existing = state.records.first(where: { $0.id == record.id }) {
            guard existing == record else { throw CoreError.conflict }; return
        }
        var updated = state; updated.records.append(record); try save(updated)
    }
    public func enqueueSpend(_ spend: PendingSpend) throws {
        try validateCommitment(referralID: spend.referralID, hash: spend.commitmentHash)
        guard UUID(uuidString: spend.operationID) != nil else { throw CoreError.invalidConfiguration }
        guard !state.spends.contains(where: { $0.referralID == spend.referralID }),
              !state.receipts.contains(where: { $0.referralID == spend.referralID }) else { throw CoreError.alreadySpent }
        var updated = state; updated.spends.append(spend); try save(updated)
    }
    /// Backward-compatible connected sync entry point. DEMO_MODE never calls supplied adapters.
    public func sync(chain: any ChainClient, api: any ReferralAPI, configuration: AppConfiguration) async throws {
        _ = try await flush(chain: chain, api: api, configuration: configuration)
    }
    public func flush(chain: any ChainClient, api: any ReferralAPI, configuration: AppConfiguration,
                      wallet: ReferralWallet? = nil) async throws -> SyncReport {
        guard configuration.allowsNetwork else { return SyncReport() }
        return try await process(chain: chain, api: api, wallet: wallet)
    }
    /// Explicitly restricted to local actors, so this path is safe while airplane mode is active.
    public func flushLocal(chain: MockChainClient, api: MockReferralAPI, wallet: ReferralWallet? = nil) async throws -> SyncReport {
        try await process(chain: chain, api: api, wallet: wallet)
    }
    private func applyReceipts(to wallet: ReferralWallet?) async throws {
        guard let wallet else { return }
        for receipt in state.receipts {
            if await wallet.entry(id: receipt.referralID) != nil {
                try await wallet.update(id: receipt.referralID, state: receipt.conflict ? .conflict : .spent)
            }
        }
    }
    private func process(chain: any ChainClient, api: any ReferralAPI, wallet: ReferralWallet?) async throws -> SyncReport {
        guard !syncing else { return SyncReport() }
        syncing = true; defer { syncing = false }
        var uploaded = 0, confirmed = 0
        var conflicts: [String] = []
        try await applyReceipts(to: wallet)
        while let record = state.records.first {
            try await chain.create(referralID: record.id, hash: record.commitmentHash)
            try await api.submit(record)
            if let wallet, await wallet.entry(id: record.id) != nil {
                try await wallet.update(id: record.id, state: .available, account: try await chain.read(referralID: record.id))
            }
            var updated = state; updated.records.removeAll { $0.id == record.id }; try save(updated)
            uploaded += 1
        }
        while let spend = state.spends.first {
            var conflict = false
            do {
                // Do not read-and-reject spent before this call: this stable operation may have won
                // previously and lost its HTTP response. The registry recognizes its operation ID.
                try await chain.spend(referralID: spend.referralID, hash: spend.commitmentHash, operationID: spend.operationID)
            } catch CoreError.alreadySpent { conflict = true }
              catch CoreError.conflict { conflict = true }
            // Transport/auth errors throw before any removal, preserving this exact operation for retry.
            var updated = state
            updated.spends.removeAll { $0.id == spend.id }
            updated.receipts.append(SpendReceipt(referralID: spend.referralID, conflict: conflict))
            try save(updated)
            try await applyReceipts(to: wallet)
            if conflict { conflicts.append(spend.referralID) } else { confirmed += 1 }
        }
        return SyncReport(uploaded: uploaded, confirmedSpends: confirmed, conflicts: conflicts)
    }
}
