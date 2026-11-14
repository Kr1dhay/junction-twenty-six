import SwiftUI
import EdgeCareCore

@MainActor final class ConversationController: ObservableObject {
    enum Phase: Equatable { case ready, calibrating, listening, processing, speaking, paused, complete }
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var noticeKey: String?
    @Published private(set) var textOnly = false
    @Published private(set) var replyAudio: String?
    private let audio = ConversationAudio()
    private let live = GeminiLiveController()
    private var task: Task<Void, Never>?
    private var generation = 0
    private var loop = VoiceConversationLoop()
    private weak var model: IntakeViewModel?
    private weak var app: AppSession?

    var active: Bool { loop.isRunning || phase == .calibrating || phase == .processing || phase == .speaking || phase == .listening }
    var statusKey: String {
        switch phase {
        case .ready: "conversationReady"
        case .calibrating: "microphoneCalibrating"
        case .listening: "conversationListening"
        case .processing: "saving"
        case .speaking: "conversationSpeaking"
        case .paused: "conversationPaused"
        case .complete: "conversationComplete"
        }
    }

    init() {
        audio.onTurn = { [weak self] data in self?.submit(audioData: data, text: nil) }
        audio.onSilence = { [weak self] in self?.pause(notice: "conversationSilence") }
        audio.onFailure = { [weak self] in self?.pause(notice: "voiceUnavailable") }
        audio.onActivity = { [weak self] in self?.model?.lastActivity = Date() }
        audio.onCalibrating = { [weak self] in self?.phase = .calibrating }
        audio.onCalibrated = { [weak self] noisy in self?.phase = .listening; if noisy { self?.noticeKey = "microphoneNoisy" } }
        live.onCalibrated = { [weak self] noisy in if noisy { self?.noticeKey = "microphoneNoisy" } }
        audio.onPlaybackFinished = { [weak self] in self?.playbackFinished() }
        live.onPhase = { [weak self] in self?.phase = $0 }
        live.onProfile = { [weak self] update in
            guard let self, self.permitted, let model = self.model else { return }
            model.language = update.detectedLanguage; model.languageChosen = true
            model.clinicalProfile = update.profile; model.concern = update.profile.concernEnglish
            model.voiceIntakeComplete = update.intakeComplete; model.lastActivity = Date()
        }
        live.onHistory = { [weak self] turn in
            guard let self, self.permitted else { return }
            self.model?.voiceHistory.append(turn)
        }
        live.onReplay = { [weak self] in self?.replyAudio = $0 }
        live.onActivity = { [weak self] in self?.model?.lastActivity = Date() }
        live.onFailure = { [weak self] in self?.pause(notice: $0) }
        live.onLimit = { [weak self] in self?.noticeKey = "conversationLimit" }
    }

    func start(model: IntakeViewModel, app: AppSession) {
        begin(model: model, app: app, text: nil)
    }

    func send(text: String, model: IntakeViewModel, app: AppSession) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        begin(model: model, app: app, text: text)
    }

    private func begin(model: IntakeViewModel, app: AppSession, text: String?) {
        stop()
        self.model = model; self.app = app
        guard permitted, let session = app.session else { return }
        noticeKey = nil; textOnly = false; replyAudio = nil; phase = .processing
        let current = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let engine = try await session.voiceEngine()
                guard !Task.isCancelled, self.generation == current, self.permitted else { return }
                if engine == .geminiLive {
                    // Ask for microphone permission before minting the one-minute connection token.
                    do { try await self.live.prepare(capture: text == nil) }
                    catch {
                        guard !Task.isCancelled, self.generation == current else { return }
                        self.pause(notice: "microphoneUnavailable"); return
                    }
                    guard !Task.isCancelled, self.generation == current else { return }
                    guard self.permitted else { self.live.stop(); return }
                    let credentials = try await session.liveVoiceSession(language: model.languageChosen ? model.language : nil,
                        profile: model.clinicalProfile, history: Array(model.voiceHistory.suffix(30)), consent: true)
                    guard !Task.isCancelled, self.generation == current else { return }
                    guard self.permitted else { self.live.stop(); return }
                    model.voiceIntakeComplete = false
                    try await self.live.run(credentials: credentials, text: text)
                } else if let text { self.submit(audioData: nil, text: text) }
                else { self.loop.start(); model.voiceIntakeComplete = false; self.listen() }
            } catch {
                guard !Task.isCancelled, self.generation == current else { return }
                self.pause(notice: "voiceUnavailable")
            }
        }
    }

    func replay(model: IntakeViewModel) {
        guard let replyAudio else { return }
        stop(); self.model = model
        phase = .speaking
        if !audio.play(replyAudio) { pause(notice: "voiceUnavailable") }
    }

    func stop(clearReply: Bool = false) {
        generation += 1
        task?.cancel(); task = nil
        loop.stop()
        live.stop()
        audio.clear(); audio.resetCalibration()
        phase = model?.voiceIntakeComplete == true ? .complete : .paused
        if clearReply { replyAudio = nil }
    }

    private var permitted: Bool {
        model?.voiceConsent == true && app?.connected == true && app?.simulateOffline == false && app?.session != nil
    }

    private func pause(notice: String) {
        stop(); noticeKey = notice
    }

    private func listen() {
        guard loop.isRunning, permitted else { stop(); return }
        let current = generation
        phase = .listening
        task = Task { [weak self] in
            guard let self else { return }
            // A short gap avoids recording the speaker's trailing sound.
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard self.generation == current, !Task.isCancelled, self.loop.isRunning, self.permitted else { return }
            let started = await self.audio.listen()
            guard self.generation == current, !Task.isCancelled else { return }
            if !started { self.pause(notice: "microphoneUnavailable") }
        }
    }

    private func submit(audioData: Data?, text: String?) {
        guard permitted, let model, let session = app?.session else { stop(); return }
        task?.cancel(); audio.clear()
        phase = .processing; noticeKey = nil; textOnly = false
        model.lastActivity = Date()
        let current = generation
        let profile = model.clinicalProfile, history = Array(model.voiceHistory.suffix(30))
        let language = model.languageChosen ? model.language : nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await session.voiceTurn(audio: audioData, mimeType: "audio/mp4", text: text,
                    language: language, profile: profile, history: history, consent: true)
                guard !Task.isCancelled, self.generation == current, self.permitted else { return }
                model.language = response.detectedLanguage; model.languageChosen = true
                model.voiceHistory.append(VoiceConversationTurn(role: "user", text: response.transcript))
                model.voiceHistory.append(VoiceConversationTurn(role: "assistant", text: response.reply))
                model.clinicalProfile = response.profile
                model.concern = response.profile.concernEnglish
                model.voiceIntakeComplete = response.intakeComplete
                model.lastActivity = Date()
                self.replyAudio = response.audioBase64
                self.textOnly = !response.speechAvailable
                self.loop.receivedResponse(conversationEnded: response.conversationEnded, speechAvailable: response.speechAvailable)
                if self.loop.reachedTurnLimit { self.noticeKey = "conversationLimit" }
                guard response.speechAvailable, let reply = response.audioBase64 else {
                    self.loop.stop()
                    self.phase = response.intakeComplete ? .complete : .paused
                    return
                }
                self.phase = .speaking
                if !self.audio.play(reply) { self.pause(notice: "voiceUnavailable") }
            } catch {
                guard !Task.isCancelled, self.generation == current else { return }
                self.pause(notice: (error as? CoreError) == .languageUncertain ? "languageUncertain" : "voiceUnavailable")
            }
        }
    }

    private func playbackFinished() {
        model?.lastActivity = Date()
        if loop.isRunning && permitted && model?.voiceIntakeComplete != true { listen() }
        else { loop.stop(); phase = model?.voiceIntakeComplete == true ? .complete : .paused }
    }
}
