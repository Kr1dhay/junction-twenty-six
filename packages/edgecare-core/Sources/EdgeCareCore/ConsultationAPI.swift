import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Consultation services live behind the backend; provider keys never reach the device.
public protocol ConsultationAPI: Sendable {
    func startSession(_ request: ConsultationSessionRequest) async throws -> ConsultationSessionCredentials
    func translate(_ request: ConsultationTranslateRequest) async throws -> ConsultationTranslation
    func draftNotes(_ request: ConsultationNotesRequest) async throws -> ConsultationNotesDraft
    func submit(_ record: ConsultationRecord) async throws
    func speak(_ request: ConsultationSpeakRequest) async throws -> ConsultationSpeech
}

/// Local (offline/demo) mode never contacts a provider: consultations need connected mode.
public struct MockConsultationAPI: ConsultationAPI {
    public init() {}
    public func startSession(_ request: ConsultationSessionRequest) async throws -> ConsultationSessionCredentials { throw CoreError.providerUnavailable }
    public func translate(_ request: ConsultationTranslateRequest) async throws -> ConsultationTranslation { throw CoreError.providerUnavailable }
    public func draftNotes(_ request: ConsultationNotesRequest) async throws -> ConsultationNotesDraft { throw CoreError.providerUnavailable }
    public func submit(_ record: ConsultationRecord) async throws { throw CoreError.providerUnavailable }
    public func speak(_ request: ConsultationSpeakRequest) async throws -> ConsultationSpeech { throw CoreError.providerUnavailable }
}

/// Uses the clinician bearer token (not the issuer token): consultations are clinician actions.
public struct RESTConsultationAPI: ConsultationAPI {
    private let transport: DemoHTTPTransport
    public init(baseURL: URL, configuration: AppConfiguration, bearerToken: String? = nil) {
        transport = DemoHTTPTransport(baseURL: baseURL, configuration: configuration, bearerToken: bearerToken, issuerToken: nil)
    }
    private func post<Body: Encodable, Response: Decodable>(_ path: [String], _ body: Body, as: Response.Type) async throws -> Response {
        let data = try await transport.request(path: path, method: "POST", body: try JSONEncoder().encode(body))
        return try JSONDecoder().decode(Response.self, from: data)
    }
    public func startSession(_ request: ConsultationSessionRequest) async throws -> ConsultationSessionCredentials {
        guard request.consent else { throw CoreError.consentRequired }
        return try await post(["demo", "consultations", "session"], request, as: ConsultationSessionCredentials.self)
    }
    public func translate(_ request: ConsultationTranslateRequest) async throws -> ConsultationTranslation {
        guard request.consent else { throw CoreError.consentRequired }
        let response = try await post(["demo", "consultations", "translate"], request, as: ConsultationTranslation.self)
        guard !response.translatedText.isEmpty, !response.speechAvailable || response.audio != nil else { throw CoreError.invalidResponse }
        return response
    }
    public func draftNotes(_ request: ConsultationNotesRequest) async throws -> ConsultationNotesDraft {
        guard request.consent else { throw CoreError.consentRequired }
        return try await post(["demo", "consultations", "notes"], request, as: ConsultationNotesDraft.self)
    }
    public func submit(_ record: ConsultationRecord) async throws {
        guard let uuid = UUID(uuidString: record.referralID) else { throw CoreError.notFound }
        _ = try await transport.request(path: ["referrals", uuid.uuidString.lowercased(), "consultations"], method: "POST", body: try JSONEncoder().encode(record))
    }
    public func speak(_ request: ConsultationSpeakRequest) async throws -> ConsultationSpeech {
        guard request.consent else { throw CoreError.consentRequired }
        return try await post(["demo", "consultations", "speak"], request, as: ConsultationSpeech.self)
    }
}
