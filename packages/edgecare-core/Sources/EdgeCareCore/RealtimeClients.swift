import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The realtime transcription socket is opened directly from the device with a short-lived token
// minted by the backend (the hosted backend cannot proxy WebSockets). Audio is 16 kHz mono PCM16
// LE and is streamed only; nothing is written to disk.

// MARK: - ElevenLabs Scribe realtime

public enum ScribeEvent: Equatable, Sendable {
    case started
    case partial(text: String, language: String?)
    /// A finished utterance. `language` is the final detection for the segment when available.
    case committed(text: String, language: String?)
    case failed(String)
    case closed
}

/// Pure protocol state: `committed_transcript` arrives first and the final `language_code` arrives
/// on `committed_transcript_with_timestamps`. If that never arrives, the pending segment is
/// released with the last partial's language when the next segment starts or the socket closes.
public struct ScribeEventParser: Sendable {
    private var pending: (text: String, language: String?)?
    private var lastPartialLanguage: String?
    public init() {}
    public mutating func ingest(_ data: Data) -> [ScribeEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["message_type"] as? String else { return [] }
        let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let language = (object["language_code"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch type {
        case "session_started": return [.started]
        case "partial_transcript":
            var events = flush()
            if let language { lastPartialLanguage = language }
            if !text.isEmpty { events.append(.partial(text: text, language: language)) }
            return events
        case "committed_transcript":
            let events = flush()
            if !text.isEmpty { pending = (text, lastPartialLanguage) }
            return events
        case "committed_transcript_with_timestamps":
            let resolved = text.isEmpty ? pending?.text ?? "" : text
            let finalLanguage = language ?? pending?.language ?? lastPartialLanguage
            pending = nil; lastPartialLanguage = nil
            return resolved.isEmpty ? [] : [.committed(text: resolved, language: finalLanguage)]
        default:
            if type.hasSuffix("error") || ["quota_exceeded", "rate_limited", "auth_error", "unaccepted_terms", "payment_issue", "queue_overflow"].contains(type) {
                return [.failed((object["error"] as? String) ?? type)]
            }
            return []
        }
    }
    public mutating func flush() -> [ScribeEvent] {
        guard let pending else { return [] }
        self.pending = nil; lastPartialLanguage = nil
        return [.committed(text: pending.text, language: pending.language)]
    }
}

public actor RealtimeScribeClient {
    private struct Chunk: Encodable {
        let messageType = "input_audio_chunk"
        let audioBase64: String
        let commit: Bool
        let sampleRate = 16000
        enum CodingKeys: String, CodingKey { case messageType = "message_type", audioBase64 = "audio_base_64", commit, sampleRate = "sample_rate" }
    }
    private let session = URLSession(configuration: .ephemeral)
    private var task: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var parser = ScribeEventParser()
    private var continuation: AsyncStream<ScribeEvent>.Continuation?
    public init() {}

    /// Two-language visits must re-detect the language on every utterance, because the language
    /// decides who spoke. Passing `language_code`/`secondary_languages` makes Scribe's detection
    /// sticky (an English reply after Finnish is still labelled Finnish), so those visits use
    /// multilingual mode with no hint (Scribe v3 Live only; other models get no hint at all).
    /// A same-language visit has nothing to tell apart, so the language is fixed for accuracy.
    public static func url(endpoint: RealtimeEndpoint, doctorLanguage: String, patientLanguage: String) throws -> URL {
        guard var components = URLComponents(string: endpoint.url), components.scheme == "wss" else { throw CoreError.invalidConfiguration }
        var items = [
            URLQueryItem(name: "model_id", value: endpoint.model),
            URLQueryItem(name: "token", value: endpoint.token),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
            URLQueryItem(name: "vad_silence_threshold_secs", value: "1.2"),
            URLQueryItem(name: "include_timestamps", value: "true"),
            URLQueryItem(name: "include_language_detection", value: "true"),
        ]
        let doctor = SpeakerResolver.normalize(doctorLanguage), patient = SpeakerResolver.normalize(patientLanguage)
        if doctor == patient {
            items.append(URLQueryItem(name: "language_code", value: doctor))
        } else if endpoint.model.hasPrefix("scribe_v3") {
            items.append(URLQueryItem(name: "multilang_mode", value: "true"))
        }
        components.queryItems = items
        guard let url = components.url else { throw CoreError.invalidConfiguration }
        return url
    }

    public func connect(endpoint: RealtimeEndpoint, doctorLanguage: String, patientLanguage: String) throws -> AsyncStream<ScribeEvent> {
        close()
        let url = try Self.url(endpoint: endpoint, doctorLanguage: doctorLanguage, patientLanguage: patientLanguage)
        let (stream, continuation) = AsyncStream.makeStream(of: ScribeEvent.self)
        self.continuation = continuation
        parser = ScribeEventParser()
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 1 << 20
        self.task = task
        task.resume()
        receiver = Task { [weak self] in await self?.receiveLoop(task) }
        return stream
    }
    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                guard task === self.task else { return }
                for event in parser.ingest(data) { continuation?.yield(event) }
            } catch {
                guard task === self.task else { return }
                for event in parser.flush() { continuation?.yield(event) }
                continuation?.yield(.closed); continuation?.finish(); continuation = nil
                return
            }
        }
    }
    public func send(pcm: Data) async {
        guard let task, !pcm.isEmpty, let body = try? JSONEncoder().encode(Chunk(audioBase64: pcm.base64EncodedString(), commit: false)),
              let text = String(data: body, encoding: .utf8) else { return }
        try? await task.send(.string(text))
    }
    /// Finalises the in-progress utterance (used before pausing or rotating tokens).
    public func commit() async {
        guard let task, let body = try? JSONEncoder().encode(Chunk(audioBase64: "", commit: true)),
              let text = String(data: body, encoding: .utf8) else { return }
        try? await task.send(.string(text))
    }
    public func close() {
        receiver?.cancel(); receiver = nil
        task?.cancel(with: .normalClosure, reason: nil); task = nil
        for event in parser.flush() { continuation?.yield(event) }
        continuation?.finish(); continuation = nil
    }
}
