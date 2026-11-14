import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
public protocol ReferralAPI: Sendable {
    func submit(_ record: ReferralRecord) async throws
    func fetchVerificationEnvelope(id: String) async throws -> ReferralRecord
    func list() async throws -> [ReferralRecord]
    func update(_ update: ReferralUpdate) async throws
    func deleteProfile(_ access: PatientProfileAccess) async throws
}
public extension ReferralAPI {
    func deleteProfile(_ access: PatientProfileAccess) async throws { throw CoreError.notConfigured }
    func list() async throws -> [ReferralRecord] { throw CoreError.notConfigured }
    func update(_ update: ReferralUpdate) async throws { throw CoreError.notConfigured }
}
public actor MockReferralAPI: ReferralAPI {
    private var records: [String: ReferralRecord]
    private var deleted: Set<String> = []
    public init(records: [ReferralRecord] = []) { self.records = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    public func submit(_ record: ReferralRecord) throws {
        guard !deleted.contains(record.id) else { throw CoreError.deleted }
        if let existing = records[record.id], existing != record { throw CoreError.conflict }
        records[record.id] = record
    }
    public func deleteProfile(_ access: PatientProfileAccess) throws {
        if let record = records[access.id] { try validateDeletionKey(record: record, key: access.key) }
        deleted.insert(access.id); records.removeValue(forKey: access.id)
    }
    public func list() -> [ReferralRecord] { records.values.sorted { $0.createdAt > $1.createdAt } }
    public func update(_ update: ReferralUpdate) throws {
        guard update.preservesIdentity else { throw CoreError.conflict }
        guard let current = records[update.record.id] else { throw CoreError.notFound }
        if current == update.record { return }
        guard current == update.expected else { throw CoreError.conflict }
        records[update.record.id] = update.record
    }
    public func fetchVerificationEnvelope(id: String) throws -> ReferralRecord {
        guard let record = records[id] else { throw CoreError.notFound }; return record
    }
}

/// Central transport guard: a DEMO_MODE client cannot send even one HTTP request.
struct DemoHTTPTransport: Sendable {
    let baseURL: URL
    let configuration: AppConfiguration
    let bearerToken: String?
    let issuerToken: String?
    func request(path: [String], method: String = "GET", body: Data? = nil, issuer: Bool = false) async throws -> Data {
        guard configuration.allowsNetwork else { throw CoreError.invalidConfiguration }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(baseURL.host ?? "")
        guard baseURL.scheme == "https" || (baseURL.scheme == "http" && loopback) else { throw CoreError.invalidConfiguration }
        let url = path.reduce(baseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = path.contains("voice") || path.contains("profile") || path.contains("notes") ? 150 : path.contains("consultations") ? 45 : 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token = issuer ? (issuerToken ?? bearerToken) : bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // An ephemeral session prevents clinician envelopes from being written to URLCache.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CoreError.invalidResponse }
        switch response.statusCode {
        case 200...299: return data
        case 401, 403: throw CoreError.unauthorized
        case 404: throw CoreError.notFound
        case 409: throw CoreError.conflict
        case 410: throw CoreError.deleted
        case 422: throw CoreError.languageUncertain
        case 503: throw CoreError.providerUnavailable
        default: throw CoreError.invalidResponse
        }
    }
}
public struct RESTReferralAPI: ReferralAPI {
    private let transport: DemoHTTPTransport
    public init(baseURL: URL, configuration: AppConfiguration, bearerToken: String? = nil, issuerToken: String? = nil) {
        transport = DemoHTTPTransport(baseURL: baseURL, configuration: configuration, bearerToken: bearerToken, issuerToken: issuerToken)
    }
    public func deleteProfile(_ access: PatientProfileAccess) async throws {
        struct Proof: Encodable { let encryption_key: String }
        _ = try await transport.request(path: ["referrals", access.id], method: "DELETE",
            body: JSONEncoder().encode(Proof(encryption_key: access.key.base64EncodedString())))
    }
    public func submit(_ record: ReferralRecord) async throws {
        _ = try await transport.request(path: ["referrals"], method: "POST", body: try JSONEncoder().encode(record), issuer: true)
    }
    public func update(_ update: ReferralUpdate) async throws {
        guard update.preservesIdentity else { throw CoreError.conflict }
        _ = try await transport.request(path: ["referrals", update.record.id], method: "PATCH", body: try JSONEncoder().encode(update), issuer: true)
    }
    public func fetchVerificationEnvelope(id: String) async throws -> ReferralRecord {
        guard let uuid = UUID(uuidString: id) else { throw CoreError.notFound }
        let data = try await transport.request(path: ["referrals", uuid.uuidString.lowercased(), "verification"])
        return try JSONDecoder().decode(ReferralRecord.self, from: data)
    }
    public func list() async throws -> [ReferralRecord] {
        struct Index: Decodable { let referrals: [Item] }
        struct Item: Decodable { let referralID: String; enum CodingKeys: String, CodingKey { case referralID = "referral_id" } }
        let data = try await transport.request(path: ["referrals"])
        let index = try JSONDecoder().decode(Index.self, from: data)
        var records: [ReferralRecord] = []
        for item in index.referrals { records.append(try await fetchVerificationEnvelope(id: item.referralID)) }
        return records
    }
}
