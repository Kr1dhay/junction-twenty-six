import Foundation
import EdgeCareCore

@MainActor final class GeminiLiveController {
    var onPhase: ((ConversationController.Phase) -> Void)?
    var onProfile: ((GeminiLiveProfileUpdate) -> Void)?
    var onHistory: ((VoiceConversationTurn) -> Void)?
    var onReplay: ((String) -> Void)?
    var onActivity: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onLimit: (() -> Void)?
    private let audio = GeminiLiveAudio()
    private var connection: GeminiLiveConnection?
    private var sender: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var input: AsyncStream<Data>.Continuation?
    private var finished = true
    private var terminal = false
    private var complete = false
    private var turnFinished = false
    private var profileReceived = false
    private var inputReceived = false
    private var capturing = false
    private var turns = 0
    private var ids: Set<String> = []
    private var userText = ""
    private var replyText = ""
    private var replyPCM = Data()
    private var lastSpeech = Date()
    private var lastResponse = Date()
    private var ready = false
    private var speaking = false
    private var endStarted: Date?
    private var generation = 0
    private var audibleOutputUntil: Date?

    init() {
        audio.onInput = { [weak self] data, power in
            guard let self, !self.finished, !self.terminal else { return }
            if power > -42 {
                self.lastSpeech = Date(); self.inputReceived = true; self.onActivity?()
            }
            if let result = self.input?.yield(data), case .dropped = result { self.fail("voiceUnavailable") }
        }
        audio.onDrain = { [weak self] in self?.drained() }
        audio.onFailure = { [weak self] in self?.fail("voiceUnavailable") }
    }

    func prepare(capture: Bool) async throws {
        stop()
        capturing = capture
        try await audio.prepare(capture: capture)
    }

    func run(credentials: GeminiLiveCredentials, text: String? = nil) async throws {
        let current = generation
        finished = false; terminal = false; complete = false; ready = false; speaking = false
        turns = 0; ids = []; userText = text ?? ""; replyText = ""; replyPCM = Data()
        inputReceived = text != nil; profileReceived = false; turnFinished = false; endStarted = nil
        lastSpeech = Date(); lastResponse = Date(); audibleOutputUntil = nil
        let connection = GeminiLiveConnection()
        self.connection = connection
        let started = Date()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, !self.finished, self.generation == current else { return }
                let now = Date()
                // Some Live sessions stream quiet PCM after a closing. Do not wait indefinitely
                // for the remote turn marker once the spoken closing has drained into silence.
                if self.terminal, let audible = self.audibleOutputUntil, !self.replyText.isEmpty,
                   now.timeIntervalSince(audible) > 2.5, self.audio.queuedFrames < 24000 {
                    self.flushHistory(); self.saveReplay(); self.finish(); return
                }
                if now.timeIntervalSince(started) >= Double(credentials.maxSessionSeconds) { self.fail("conversationLimit"); return }
                if !self.ready && now.timeIntervalSince(started) > 15 { self.fail("voiceUnavailable"); return }
                if let end = self.endStarted, now.timeIntervalSince(end) > 20 { self.fail("voiceUnavailable"); return }
                if self.ready && !self.terminal && !self.speaking && !self.inputReceived && now.timeIntervalSince(self.lastSpeech) > 12 {
                    self.fail("conversationSilence"); return
                }
                if self.ready && (self.inputReceived || self.speaking) && now.timeIntervalSince(self.lastResponse) > 30 {
                    self.fail("voiceUnavailable"); return
                }
            }
        }
        do {
            try await connection.connect(credentials)
            while !finished, !Task.isCancelled, generation == current {
                let event = try await connection.receive()
                guard !finished, generation == current, !Task.isCancelled else { return }
                lastResponse = Date()
                if event.error != nil || event.goAway != nil { throw CoreError.providerUnavailable }
                if event.setupComplete != nil {
                    guard !ready else { throw CoreError.invalidResponse }
                    ready = true
                    if capturing {
                        let pipe = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(12))
                        input = pipe.continuation
                        sender = Task { [weak self] in
                            do {
                                for await chunk in pipe.stream {
                                    guard !Task.isCancelled, let self, !self.finished, !self.terminal else { return }
                                    try await connection.sendAudio(chunk)
                                }
                            } catch { if !Task.isCancelled { self?.fail("voiceUnavailable") } }
                        }
                        try audio.startCapture()
                        onPhase?(.listening)
                    } else if let text { try await connection.sendText(text); onPhase?(.processing) }
                }
                if let tool = event.toolCall {
                    guard tool.functionCalls.count == 1, inputReceived else { throw CoreError.invalidResponse }
                    for call in tool.functionCalls {
                        guard call.name == "record_intake_profile", !call.id.isEmpty, call.id.count <= 200 else { throw CoreError.invalidResponse }
                        if ids.contains(call.id) { try await connection.acknowledge(call); continue }
                        guard !profileReceived else { throw CoreError.invalidResponse }
                        try call.args.validate()
                        ids.insert(call.id); turns += 1; profileReceived = true
                        complete = call.args.intakeComplete
                        onProfile?(call.args); onActivity?()
                        let limited = turns >= 6 && capturing
                        terminal = call.args.conversationEnded || limited || !capturing
                        if limited { onLimit?() }
                        if terminal {
                            endStarted = Date(); audio.stopCapture(); input?.finish(); input = nil
                        }
                        try await connection.acknowledge(call, endSession: limited)
                        if terminal && capturing { try await connection.endAudio() }
                    }
                }
                if let content = event.serverContent {
                    if content.interrupted == true {
                        audio.interruptPlayback(); flushHistory(); replyPCM = Data()
                        profileReceived = false; inputReceived = false; turnFinished = false; speaking = false
                    }
                    if let text = content.inputTranscription?.text {
                        guard userText.count + text.count <= 4000 else { throw CoreError.invalidResponse }
                        userText += text; inputReceived = true; onActivity?()
                    }
                    if let text = content.outputTranscription?.text {
                        guard replyText.count + text.count <= 4000 else { throw CoreError.invalidResponse }
                        replyText += text
                    }
                    // A message may include several audio parts AND transcripts/tools.
                    for part in content.modelTurn?.parts ?? [] {
                        guard let inline = part.inlineData else { continue }
                        guard inline.mimeType.hasPrefix("audio/pcm"), inline.mimeType.contains("rate=24000"),
                              let data = Data(base64Encoded: inline.data), replyPCM.count + data.count <= 2 * 1024 * 1024 else { throw CoreError.invalidResponse }
                        try audio.enqueue(data); replyPCM.append(data)
                        if (PCM16Audio.power(data) ?? -90) > -50 {
                            audibleOutputUntil = Date().addingTimeInterval(Double(audio.queuedFrames) / 24000)
                        }
                        speaking = true; onPhase?(.speaking); onActivity?()
                    }
                    if content.turnComplete == true && content.interrupted != true {
                        guard !inputReceived || profileReceived else { throw CoreError.invalidResponse }
                        turnFinished = true
                        flushHistory()
                        saveReplay()
                        if audio.queuedFrames == 0 { drained() }
                    }
                }
            }
        } catch {
            if !finished, generation == current, !Task.isCancelled { stop(); throw error }
        }
    }

    private func drained() {
        guard !finished, turnFinished else { return }
        speaking = false
        if terminal {
            finish()
        } else {
            turnFinished = false; profileReceived = false; inputReceived = false
            lastSpeech = Date(); onPhase?(.listening)
        }
    }
    private func flushHistory() {
        if !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onHistory?(VoiceConversationTurn(role: "user", text: userText)) }
        if !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onHistory?(VoiceConversationTurn(role: "assistant", text: replyText)) }
        userText = ""; replyText = ""
    }
    private func fail(_ notice: String) { guard !finished else { return }; stop(); onFailure?(notice) }
    private func finish() { let completed = complete; stop(); onPhase?(completed ? .complete : .paused) }
    private func saveReplay() {
        if let data = try? PCM16Audio.wave(replyPCM) { onReplay?(data.base64EncodedString()) }
        replyPCM = Data()
    }
    func stop() {
        generation += 1; finished = true; ready = false
        watchdog?.cancel(); watchdog = nil; sender?.cancel(); sender = nil
        input?.finish(); input = nil
        audio.stop(); connection?.close(); connection = nil
        userText = ""; replyText = ""; replyPCM = Data(); ids = []
    }
}
