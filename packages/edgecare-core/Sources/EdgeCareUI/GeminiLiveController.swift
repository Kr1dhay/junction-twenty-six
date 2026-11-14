import Foundation
import EdgeCareCore

@MainActor final class GeminiLiveController {
    var onEchoCancellationUnavailable: (() -> Void)?
    var onInterruption: (() -> Void)?
    private var microphone = GeminiLiveMicrophoneInput()
    private var interruptionGate = LiveInterruptionGate()
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
    private var input: AsyncStream<GeminiLiveInput>.Continuation?
    private var finished = true
    private var terminal = false
    private var complete = false
    private var turnFinished = false
    private var profileReceived = false
    private var inputReceived = false
    private var capturing = false
    private var turns = 0
    private var ids: Set<String> = []
    private var cancelledCalls: Set<String> = []
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
            guard let self, !self.finished else { return }
            // Capture stays live during output, including the closing acknowledgement.
            // Voice Processing I/O handles echo; never blanket-mute the patient's mic.
            let playing = self.speaking || self.audio.queuedFrames > 0 || self.terminal
            guard let frame = self.microphone.process(data, power: power, duringPlayback: playing) else { return }
            if frame.activity.speechStarted,
               self.speaking || self.audio.queuedFrames > 0 || self.terminal,
               self.interruptionGate.interrupt(awaitingServer: !self.turnFinished) {
                self.interruptReply()
                NSLog("EdgeCare voice: local barge-in; playback stopped")
            }
            if frame.activity.speechDetected {
                self.lastSpeech = Date(); self.inputReceived = true; self.onActivity?()
                if !self.speaking { self.onPhase?(.listening) }
            }
            if frame.activity.speechEnded, !self.speaking, !self.terminal {
                self.onPhase?(.processing)
                NSLog("EdgeCare voice: end of utterance detected")
            }
            for message in frame.messages { self.sendInput(message) }
        }
        audio.onDrain = { [weak self] in self?.drained() }
        audio.onFailure = { [weak self] in self?.fail("voiceUnavailable") }
        audio.onCaptureFailure = { [weak self] in self?.fail("microphoneUnavailable") }
    }

    func prepare(capture: Bool) async throws {
        stop()
        capturing = capture
        try await audio.prepare(capture: capture)
    }

    func run(credentials: GeminiLiveCredentials, text: String? = nil) async throws {
        let current = generation
        finished = false; terminal = false; complete = false; ready = false; speaking = false
        microphone = GeminiLiveMicrophoneInput(); interruptionGate = LiveInterruptionGate()
        turns = 0; ids = []; cancelledCalls = []
        userText = text ?? ""; replyText = ""; replyPCM = Data()
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
                if !self.terminal, let audible = self.audibleOutputUntil,
                   now.timeIntervalSince(audible) > 12, now.timeIntervalSince(self.lastSpeech) > 12 {
                    self.fail("conversationSilence"); return
                }
                if self.ready, self.inputReceived, self.audibleOutputUntil == nil,
                   now.timeIntervalSince(self.lastSpeech) > 30 { self.fail("voiceUnavailable"); return }
                if now.timeIntervalSince(started) >= Double(credentials.maxSessionSeconds) { self.fail("conversationLimit"); return }
                if !self.ready && now.timeIntervalSince(started) > 15 { self.fail("voiceUnavailable"); return }
                if let end = self.endStarted, now.timeIntervalSince(end) > 20 { self.fail("voiceUnavailable"); return }
                if self.ready && !self.terminal && !self.speaking && !self.inputReceived && now.timeIntervalSince(self.lastSpeech) > 12 {
                    self.fail("conversationSilence"); return
                }
                if self.ready && (self.inputReceived || self.speaking) && now.timeIntervalSince(max(self.lastResponse, self.lastSpeech)) > 30 {
                    self.fail("voiceUnavailable"); return
                }
            }
        }
        do {
            try await connection.connect(credentials)
            if capturing && !audio.hasEchoCancellation { onEchoCancellationUnavailable?() }
            while !finished, !Task.isCancelled, generation == current {
                let event = try await connection.receive()
                guard !finished, generation == current, !Task.isCancelled else { return }
                lastResponse = Date()
                if event.error != nil || event.goAway != nil { throw CoreError.providerUnavailable }
                if event.setupComplete != nil {
                    guard !ready else { throw CoreError.invalidResponse }
                    ready = true; lastSpeech = Date()
                    if capturing {
                        let pipe = AsyncStream<GeminiLiveInput>.makeStream(bufferingPolicy: .bufferingOldest(12))
                        input = pipe.continuation
                        sender = Task { [weak self] in
                            do {
                                for await message in pipe.stream {
                                    guard !Task.isCancelled, let self, !self.finished else { return }
                                    try await connection.sendInput(message)
                                    if case .endUtterance = message { NSLog("EdgeCare voice: Gemini input finalized after pause") }
                                }
                            } catch {
                                if !Task.isCancelled {
                                    let code = error as NSError
                                    NSLog("EdgeCare voice: audio send failed domain=%@ code=%ld", code.domain, code.code)
                                    self?.fail("voiceUnavailable")
                                }
                            }
                        }
                        do { try audio.startCapture() }
                        catch { fail("microphoneUnavailable"); return }
                        onPhase?(.listening)
                    } else if let text { try await connection.sendText(text); onPhase?(.processing) }
                }
                // Transcripts and interruptions can arrive in the same message as a
                // tool call. Apply them first; Google does not guarantee their order.
                if let cancellation = event.toolCallCancellation {
                    guard cancellation.ids.count <= 100, cancelledCalls.count + cancellation.ids.count <= 200 else { throw CoreError.invalidResponse }
                    cancelledCalls.formUnion(cancellation.ids)
                }
                if let content = event.serverContent {
                    if content.interrupted == true {
                        if !interruptionGate.awaitingAcknowledgment { interruptReply() }
                        NSLog("EdgeCare voice: server interruption acknowledged")
                    }
                    if let text = content.inputTranscription?.text {
                        guard userText.count + text.count <= 4000 else { throw CoreError.invalidResponse }
                        userText += text; inputReceived = true; lastSpeech = Date(); onActivity?()
                    }
                }
                // A turn may finish just before Google receives the interruption.
                // In that race there is no `interrupted` event. Drop the remainder
                // of the old turn and release the gate for the patient's next reply.
                if interruptionGate.discardOutput(interrupted: event.serverContent?.interrupted == true,
                    turnComplete: event.serverContent?.turnComplete == true,
                    hasNewOutput: event.toolCall != nil || event.serverContent?.modelTurn != nil ||
                        event.serverContent?.outputTranscription?.text != nil) {
                    if let tool = event.toolCall {
                        for call in tool.functionCalls where !cancelledCalls.contains(call.id) {
                            try await connection.acknowledge(call, superseded: true)
                        }
                    }
                    continue
                }
                if let tool = event.toolCall {
                    guard tool.functionCalls.count == 1, inputReceived else { throw CoreError.invalidResponse }
                    for call in tool.functionCalls {
                        if cancelledCalls.contains(call.id) { continue }
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
                            // Do not close capture until the closing audio finishes. The
                            // patient may interrupt with a correction before that point.
                            endStarted = Date()
                        }
                        try await connection.acknowledge(call, endSession: limited)
                    }
                }
                if let content = event.serverContent, interruptionGate.acceptsOutput {
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
                            speaking = true; onPhase?(.speaking); onActivity?()
                        }
                    }
                    if content.turnComplete == true && content.interrupted != true {
                        // Gemini 3.8 proactive audio may decline irrelevant input
                        // without a profile tool. That is a completed/ignored turn,
                        // not a failed provider session. Cancelled old completions
                        // have already been discarded by the interruption gate.
                        if inputReceived && !profileReceived {
                            NSLog("EdgeCare voice: Gemini completed without profile; retaining accepted profile")
                        }
                        turnFinished = true
                        flushHistory()
                        saveReplay()
                        if audio.queuedFrames == 0 { drained() }
                    }
                }
            }
        } catch {
            if !finished, generation == current, !Task.isCancelled {
                let code = error as NSError
                NSLog("EdgeCare voice: session failed domain=%@ code=%ld input=%d profile=%d", code.domain, code.code,
                      inputReceived ? 1 : 0, profileReceived ? 1 : 0)
                stop(); throw error
            }
        }
    }

    private func interruptReply() {
        audio.interruptPlayback()
        flushHistory(); replyPCM = Data()
        profileReceived = false; turnFinished = false; speaking = false
        terminal = false; complete = false; inputReceived = true; endStarted = nil
        audibleOutputUntil = nil; lastSpeech = Date(); lastResponse = Date()
        onInterruption?(); onPhase?(.listening)
    }

    private func sendInput(_ message: GeminiLiveInput) {
        if let result = input?.yield(message), case .dropped = result { fail("voiceUnavailable") }
    }

    private func drained() {
        guard !finished, turnFinished else { return }
        speaking = false
        if terminal {
            finish()
        } else {
            turnFinished = false; profileReceived = false; inputReceived = false
            audibleOutputUntil = Date(); lastSpeech = Date(); onPhase?(.listening)
        }
    }
    private func flushHistory() {
        if !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onHistory?(VoiceConversationTurn(role: "user", text: userText)) }
        if !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onHistory?(VoiceConversationTurn(role: "assistant", text: replyText)) }
        userText = ""; replyText = ""
    }
    private func fail(_ notice: String) {
        guard !finished else { return }
        NSLog("EdgeCare voice: stopping reason=%@", notice)
        stop(); onFailure?(notice)
    }
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
        userText = ""; replyText = ""; replyPCM = Data(); ids = []; cancelledCalls = []
        microphone = GeminiLiveMicrophoneInput(); interruptionGate = LiveInterruptionGate()
    }
}
