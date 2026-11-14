import Foundation

/// Canonical clinical values are English even when conversation and playback use another language.
public struct ClinicalProfile: Codable, Equatable, Sendable {
    public var concernEnglish: String
    public var symptomsEnglish: [String]
    public var durationEnglish: String
    public var additionalContextEnglish: String
    public init(concernEnglish: String = "", symptomsEnglish: [String] = [], durationEnglish: String = "", additionalContextEnglish: String = "") {
        self.concernEnglish = concernEnglish; self.symptomsEnglish = symptomsEnglish
        self.durationEnglish = durationEnglish; self.additionalContextEnglish = additionalContextEnglish
    }
    public var clinicianSummary: String {
        [concernEnglish, symptomsEnglish.isEmpty ? "" : "Symptoms: " + symptomsEnglish.joined(separator: ", "),
         durationEnglish.isEmpty ? "" : "Duration: " + durationEnglish, additionalContextEnglish]
            .filter { !$0.isEmpty }.joined(separator: ". ")
    }
    enum CodingKeys: String, CodingKey {
        case concernEnglish = "concern_english", symptomsEnglish = "symptoms_english"
        case durationEnglish = "duration_english", additionalContextEnglish = "additional_context_english"
    }
}
public struct VoiceConversationTurn: Codable, Equatable, Sendable {
    public let role: String
    public let text: String
    public init(role: String, text: String) { self.role = role; self.text = text }
}
public struct VoiceTurnRequest: Encodable, Sendable {
    public let consent: Bool
    public let audioBase64: String?
    public let audioMimeType: String?
    public let text: String?
    public let language: String?
    public let profile: ClinicalProfile
    public let history: [VoiceConversationTurn]
    public init(consent: Bool, audio: Data? = nil, mimeType: String = "audio/mp4", text: String? = nil,
                language: String? = nil, profile: ClinicalProfile = ClinicalProfile(), history: [VoiceConversationTurn] = []) {
        self.consent = consent; audioBase64 = audio?.base64EncodedString(); audioMimeType = audio == nil ? nil : mimeType
        self.text = text; self.language = language; self.profile = profile; self.history = Array(history.suffix(30))
    }
    enum CodingKeys: String, CodingKey {
        case consent, audioBase64 = "audio_base64", audioMimeType = "audio_mime_type", text, language, profile, history
    }
}
public struct VoiceTurnResponse: Decodable, Sendable {
    public let transcript: String
    public let detectedLanguage: String
    public let reply: String
    public let profile: ClinicalProfile
    public let intakeComplete: Bool
    public let conversationEnded: Bool
    public let audioBase64: String?
    public let audioMimeType: String?
    public let speechAvailable: Bool
    public let speechError: String?
    public var audio: Data? { audioBase64.flatMap { Data(base64Encoded: $0) } }
    enum CodingKeys: String, CodingKey {
        case transcript, detectedLanguage = "detected_language", reply, profile, audioBase64 = "audio_base64", audioMimeType = "audio_mime_type"
        case speechAvailable = "speech_available", speechError = "speech_error"
        case intakeComplete = "intake_complete"
        case conversationEnded = "conversation_ended"
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        transcript = try values.decode(String.self, forKey: .transcript)
        detectedLanguage = try values.decode(String.self, forKey: .detectedLanguage)
        reply = try values.decode(String.self, forKey: .reply)
        profile = try values.decode(ClinicalProfile.self, forKey: .profile)
        // Older backends may omit completion. The automatic session still has a turn limit.
        intakeComplete = try values.decodeIfPresent(Bool.self, forKey: .intakeComplete) ?? false
        conversationEnded = try values.decodeIfPresent(Bool.self, forKey: .conversationEnded) ?? intakeComplete
        audioBase64 = try values.decodeIfPresent(String.self, forKey: .audioBase64)
        audioMimeType = try values.decodeIfPresent(String.self, forKey: .audioMimeType)
        speechAvailable = try values.decode(Bool.self, forKey: .speechAvailable)
        speechError = try values.decodeIfPresent(String.self, forKey: .speechError)
    }
}
/// Uses only our configured backend. Provider keys remain server-side and no upload occurs without consent.
public struct ConsentGatedVoiceClient: Sendable {
    private let transport: DemoHTTPTransport
    public init(baseURL: URL, configuration: AppConfiguration, bearerToken: String? = nil) {
        transport = DemoHTTPTransport(baseURL: baseURL, configuration: configuration, bearerToken: bearerToken, issuerToken: bearerToken)
    }
    public func turn(_ request: VoiceTurnRequest) async throws -> VoiceTurnResponse {
        try await send(request, path: ["demo", "voice", "turn"])
    }
    public func normalize(_ request: VoiceTurnRequest) async throws -> VoiceTurnResponse {
        try await send(request, path: ["demo", "profile", "normalize"])
    }
    public func engine() async throws -> VoiceEngine {
        struct Configuration: Decodable { let engine: VoiceEngine }
        do {
            return try JSONDecoder().decode(Configuration.self, from: await transport.request(path: ["demo", "voice", "config"])).engine
        } catch CoreError.notFound { return .legacy } // Backward-compatible with older demo servers.
    }
    public func liveSession(consent: Bool, language: String?, profile: ClinicalProfile, history: [VoiceConversationTurn]) async throws -> GeminiLiveCredentials {
        guard consent else { throw CoreError.consentRequired }
        struct Context: Encodable {
            let consent: Bool; let language: String?; let profile: ClinicalProfile; let history: [VoiceConversationTurn]
        }
        let body = try JSONEncoder().encode(Context(consent: consent, language: language, profile: profile, history: Array(history.suffix(30))))
        let data = try await transport.request(path: ["demo", "voice", "live", "session"], method: "POST", body: body, issuer: true)
        let credentials = try JSONDecoder().decode(GeminiLiveCredentials.self, from: data)
        _ = try credentials.request()
        return credentials
    }
    private func send(_ request: VoiceTurnRequest, path: [String]) async throws -> VoiceTurnResponse {
        guard request.consent else { throw CoreError.consentRequired }
        guard request.audioBase64 != nil || !(request.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else { throw CoreError.emptyConcern }
        let data = try await transport.request(path: path, method: "POST", body: try JSONEncoder().encode(request), issuer: true)
        let response = try JSONDecoder().decode(VoiceTurnResponse.self, from: data)
        guard !response.reply.isEmpty, !response.detectedLanguage.isEmpty, !response.speechAvailable || response.audio != nil else { throw CoreError.invalidResponse }
        return response
    }
}
public typealias VoiceClient = ConsentGatedVoiceClient
