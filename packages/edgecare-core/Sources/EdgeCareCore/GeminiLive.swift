import Foundation

public enum VoiceEngine: String, Decodable, Sendable { case geminiLive = "gemini_live", legacy }

/// Short-lived, single-session credentials. Never persisted in the wallet or outbox.
public struct GeminiLiveCredentials: Decodable, Sendable {
    public let token: String
    public let model: String
    public let websocketURL: String
    public let setupJSON: String
    public let maxSessionSeconds: Int
    enum CodingKeys: String, CodingKey {
        case token, model, websocketURL = "websocket_url", setupJSON = "setup_json", maxSessionSeconds = "max_session_seconds"
    }
    public func request() throws -> URLRequest {
        let endpoint = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained"
        guard websocketURL == endpoint, model == "gemini-3.8-live", !token.isEmpty, token.utf8.count <= 16384,
              !token.contains("\r"), !token.contains("\n"), setupJSON.utf8.count <= 256 * 1024,
              (1...300).contains(maxSessionSeconds), let url = URL(string: endpoint) else { throw CoreError.invalidResponse }
        var request = URLRequest(url: url)
        // Header authentication keeps the temporary token out of URL logs.
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }
}

public struct GeminiLiveProfileUpdate: Decodable, Sendable {
    public let detectedLanguage: String
    public let profile: ClinicalProfile
    public let stopRequested: Bool
    public var intakeComplete: Bool {
        !profile.concernEnglish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && profile.symptomsEnglish.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && !profile.durationEnglish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public var conversationEnded: Bool { intakeComplete || stopRequested }
    enum CodingKeys: String, CodingKey { case detectedLanguage = "detected_language", profile, stopRequested = "stop_requested" }
    public func validate() throws {
        guard detectedLanguage.range(of: "^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil,
              profile.concernEnglish.count <= 4000, profile.symptomsEnglish.count <= 30,
              profile.symptomsEnglish.allSatisfy({ $0.count <= 200 }), profile.durationEnglish.count <= 500,
              profile.additionalContextEnglish.count <= 4000 else { throw CoreError.invalidResponse }
    }
}

public struct GeminiLiveEvent: Decodable, Sendable {
    public struct Empty: Decodable, Sendable {}
    public struct Transcript: Decodable, Sendable { public let text: String? }
    public struct InlineAudio: Decodable, Sendable { public let mimeType: String; public let data: String }
    public struct Part: Decodable, Sendable { public let inlineData: InlineAudio?; public let text: String?; public let thought: Bool? }
    public struct ModelTurn: Decodable, Sendable { public let parts: [Part]? }
    public struct Content: Decodable, Sendable {
        public let modelTurn: ModelTurn?
        public let inputTranscription: Transcript?
        public let outputTranscription: Transcript?
        public let interrupted: Bool?
        public let turnComplete: Bool?
    }
    public struct Call: Decodable, Sendable {
        public let id: String
        public let name: String
        public let args: GeminiLiveProfileUpdate
    }
    public struct ToolCall: Decodable, Sendable { public let functionCalls: [Call] }
    public let setupComplete: Empty?
    public let serverContent: Content?
    public let toolCall: ToolCall?
    public let goAway: Empty?
    public let error: Empty?
}

/// Direct PCM streaming to Google with an ephemeral credential, bypassing HTTP turn buffering.
@MainActor public final class GeminiLiveConnection {
    private let session = URLSession(configuration: .ephemeral)
    private var socket: URLSessionWebSocketTask?
    public init() {}
    public func connect(_ credentials: GeminiLiveCredentials) async throws {
        let socket = session.webSocketTask(with: try credentials.request())
        socket.maximumMessageSize = 2 * 1024 * 1024
        self.socket = socket
        socket.resume()
        try await socket.send(.string(credentials.setupJSON))
    }
    public func receive() async throws -> GeminiLiveEvent {
        guard let socket else { throw CoreError.notConfigured }
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw CoreError.invalidResponse
        }
        guard data.count <= 2 * 1024 * 1024 else { throw CoreError.invalidResponse }
        return try JSONDecoder().decode(GeminiLiveEvent.self, from: data)
    }
    public func sendAudio(_ data: Data) async throws {
        guard !data.isEmpty, data.count <= 32 * 1024, data.count.isMultiple(of: 2) else { throw CoreError.invalidResponse }
        try await send(["realtimeInput": ["audio": ["data": data.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
    }
    public func sendText(_ text: String) async throws {
        guard !text.isEmpty, text.count <= 4000 else { throw CoreError.invalidResponse }
        try await send(["realtimeInput": ["text": text]])
    }
    public func endAudio() async throws { try await send(["realtimeInput": ["audioStreamEnd": true]]) }
    public func acknowledge(_ call: GeminiLiveEvent.Call, endSession: Bool = false) async throws {
        try await send(["toolResponse": ["functionResponses": [["id": call.id, "name": call.name,
            "response": ["saved_in_session": true, "intake_complete": call.args.intakeComplete,
                "conversation_ended": call.args.conversationEnded || endSession]]]]])
    }
    private func send(_ object: [String: Any]) async throws {
        guard let socket else { throw CoreError.notConfigured }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw CoreError.invalidResponse }
        try await socket.send(.string(text))
    }
    public func close() {
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session.invalidateAndCancel()
    }
}
