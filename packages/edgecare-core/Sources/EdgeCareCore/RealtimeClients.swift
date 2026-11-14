import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Both realtime sockets are opened directly from the device with short-lived tokens minted by
// the backend (the hosted backend cannot proxy WebSockets). Audio is 16 kHz mono PCM16 LE and
// is streamed only; nothing is written to disk.

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

    /// Constrains recognition to the two consultation languages so short phrases are not
    /// attributed to an unrelated language.
    public static func url(endpoint: RealtimeEndpoint, doctorLanguage: String, patientLanguage: String) throws -> URL {
        guard var components = URLComponents(string: endpoint.url), components.scheme == "wss" else { throw CoreError.invalidConfiguration }
        components.queryItems = [
            URLQueryItem(name: "model_id", value: endpoint.model),
            URLQueryItem(name: "token", value: endpoint.token),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
            URLQueryItem(name: "vad_silence_threshold_secs", value: "1.2"),
            URLQueryItem(name: "include_timestamps", value: "true"),
            URLQueryItem(name: "include_language_detection", value: "true"),
            URLQueryItem(name: "language_code", value: SpeakerResolver.normalize(doctorLanguage)),
            URLQueryItem(name: "secondary_languages", value: SpeakerResolver.normalize(patientLanguage)),
        ]
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

// MARK: - Gemini Live recorder

public enum LiveRecorderEvent: Equatable, Sendable {
    case ready
    /// Gemini's own transcription of what it heard (an independent transcript for cross-checking).
    case heard(String)
    /// Running "key points" bullets produced by the fixed scribe instruction.
    case keyPoints([String])
    case resumptionHandle(String)
    case goAway
    case failed(String)
    case closed
}

public struct LiveEventParser: Sendable {
    private var modelText = ""
    public init() {}
    public mutating func ingest(_ data: Data) -> [LiveRecorderEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var events: [LiveRecorderEvent] = []
        if object["setupComplete"] != nil { events.append(.ready) }
        if let content = object["serverContent"] as? [String: Any] {
            if let input = content["inputTranscription"] as? [String: Any], let text = input["text"] as? String, !text.isEmpty {
                events.append(.heard(text))
            }
            if let turn = content["modelTurn"] as? [String: Any], let parts = turn["parts"] as? [[String: Any]] {
                modelText += parts.compactMap { $0["text"] as? String }.joined()
            }
            if content["turnComplete"] as? Bool == true || content["generationComplete"] as? Bool == true {
                let points = modelText.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("- ") && $0.count > 2 }
                    .map { String($0.dropFirst(2)) }
                modelText = ""
                if !points.isEmpty { events.append(.keyPoints(points)) }
            }
        }
        if let update = object["sessionResumptionUpdate"] as? [String: Any], update["resumable"] as? Bool != false,
           let handle = update["newHandle"] as? String, !handle.isEmpty { events.append(.resumptionHandle(handle)) }
        if object["goAway"] != nil { events.append(.goAway) }
        if let error = object["error"] as? [String: Any] { events.append(.failed((error["message"] as? String) ?? "Gemini Live error")) }
        return events
    }
}

public actor GeminiLiveRecorder {
    private let session = URLSession(configuration: .ephemeral)
    private var task: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var parser = LiveEventParser()
    private var continuation: AsyncStream<LiveRecorderEvent>.Continuation?
    private var ready = false
    public init() {}

    /// The server locks model, modalities and instruction into the token; the setup repeats them
    /// only because the protocol requires a setup message.
    public static func setupMessage(model: String, resumptionHandle: String?) -> Data {
        var resumption: [String: Any] = [:]
        if let resumptionHandle { resumption["handle"] = resumptionHandle }
        let setup: [String: Any] = ["setup": [
            "model": model.hasPrefix("models/") ? model : "models/\(model)",
            "generationConfig": ["responseModalities": ["TEXT"]],
            "inputAudioTranscription": [String: Any](),
            "sessionResumption": resumption,
            "contextWindowCompression": ["slidingWindow": [String: Any]()],
        ]]
        return (try? JSONSerialization.data(withJSONObject: setup, options: [.sortedKeys])) ?? Data()
    }

    public func connect(endpoint: RealtimeEndpoint, resumptionHandle: String? = nil) throws -> AsyncStream<LiveRecorderEvent> {
        close()
        guard var components = URLComponents(string: endpoint.url), components.scheme == "wss" else { throw CoreError.invalidConfiguration }
        components.queryItems = [URLQueryItem(name: "access_token", value: endpoint.token)]
        guard let url = components.url else { throw CoreError.invalidConfiguration }
        let (stream, continuation) = AsyncStream.makeStream(of: LiveRecorderEvent.self)
        self.continuation = continuation
        parser = LiveEventParser(); ready = false
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 4 << 20
        self.task = task
        task.resume()
        let setup = Self.setupMessage(model: endpoint.model, resumptionHandle: resumptionHandle)
        receiver = Task { [weak self] in
            do { try await task.send(.string(String(decoding: setup, as: UTF8.self))) }
            catch { await self?.finish(task, failure: "Gemini Live could not start.") ; return }
            await self?.receiveLoop(task)
        }
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
                for event in parser.ingest(data) {
                    if event == .ready { ready = true }
                    continuation?.yield(event)
                }
            } catch {
                await finish(task, failure: nil); return
            }
        }
    }
    private func finish(_ task: URLSessionWebSocketTask, failure: String?) async {
        guard task === self.task else { return }
        if let failure { continuation?.yield(.failed(failure)) }
        continuation?.yield(.closed); continuation?.finish(); continuation = nil
        self.task = nil; ready = false
    }
    public func send(pcm: Data) async {
        guard ready, let task, !pcm.isEmpty else { return }
        let message: [String: Any] = ["realtimeInput": ["audio": ["data": pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]]
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? await task.send(.string(String(decoding: body, as: UTF8.self)))
    }
    public func endAudio() async {
        guard ready, let task else { return }
        try? await task.send(.string(#"{"realtimeInput":{"audioStreamEnd":true}}"#))
    }
    public func close() {
        receiver?.cancel(); receiver = nil
        task?.cancel(with: .normalClosure, reason: nil); task = nil; ready = false
        continuation?.finish(); continuation = nil
    }
}
