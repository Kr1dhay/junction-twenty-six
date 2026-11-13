import Foundation
public actor ReferralOutbox {
    private let url: URL
    private var records: [ReferralRecord]
    private var syncing = false
    public init(storeURL: URL) throws {
        url = storeURL
        records = FileManager.default.fileExists(atPath: storeURL.path)
            ? try JSONDecoder().decode([ReferralRecord].self, from: Data(contentsOf: storeURL)) : []
    }
    public func pending() -> [ReferralRecord] { records }
    private func save(_ updated: [ReferralRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try JSONEncoder().encode(updated).write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        #endif
        records = updated
    }
    public func enqueue(_ record: ReferralRecord) throws {
        if let existing = records.first(where: { $0.id == record.id }) {
            guard existing == record else { throw CoreError.conflict }; return
        }
        try save(records + [record])
    }
    public func sync(chain: any ChainClient, api: any ReferralAPI, configuration: AppConfiguration) async throws {
        guard configuration.allowsNetwork, !syncing else { return }
        syncing = true; defer { syncing = false }
        while let record = records.first {
            try await chain.create(referralID: record.id, hash: record.commitmentHash)
            try await api.submit(record)
            try save(records.filter { $0.id != record.id })
        }
    }
}
