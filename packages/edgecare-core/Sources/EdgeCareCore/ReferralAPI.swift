import Foundation
public protocol ReferralAPI: Sendable {
    func submit(_ record: ReferralRecord) async throws
    func fetchVerificationEnvelope(id: String) async throws -> ReferralRecord
}
public actor MockReferralAPI: ReferralAPI {
    private var records: [String: ReferralRecord]
    public init(records: [ReferralRecord] = []) { self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }) }
    public func submit(_ record: ReferralRecord) throws {
        if let existing = records[record.id], existing != record { throw CoreError.conflict }
        records[record.id] = record
    }
    public func fetchVerificationEnvelope(id: String) throws -> ReferralRecord {
        guard let record = records[id] else { throw CoreError.notFound }; return record
    }
}
public struct RESTReferralAPI: ReferralAPI {
    private let baseURL: URL
    private let configuration: AppConfiguration
    public init(baseURL: URL, configuration: AppConfiguration) { self.baseURL = baseURL; self.configuration = configuration }
    public func submit(_ record: ReferralRecord) async throws {
        guard configuration.allowsNetwork else { throw CoreError.invalidConfiguration }
        var request = URLRequest(url: baseURL.appendingPathComponent("referrals"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(record)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, [200, 201].contains(response.statusCode) else { throw CoreError.conflict }
    }
    public func fetchVerificationEnvelope(id: String) async throws -> ReferralRecord {
        guard configuration.allowsNetwork else { throw CoreError.invalidConfiguration }
        let url = baseURL.appendingPathComponent("referrals").appendingPathComponent(id).appendingPathComponent("verification")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CoreError.notFound }
        return try JSONDecoder().decode(ReferralRecord.self, from: data)
    }
}
