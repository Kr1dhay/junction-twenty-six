import SwiftUI
import EdgeCareCore

@MainActor final class ConversationController: ObservableObject {
    enum Phase: Equatable { case ready, connecting, listening, processing, speaking, paused, complete }
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var noticeKey: String?
    @Published private(set) var textOnly = false
    @Published private(set) var replyAudio: String?
    private let audio = ConversationAudio()
    private let live = GeminiLiveController()
    private var task: Task<Void, Never>?
    private var generation = 0
    private weak var model: IntakeViewModel?
    private weak var app: AppSession?

    var active: Bool { phase == .connecting || phase == .processing || phase == .speaking || phase == .listening }
    var statusKey: String {
        switch phase {
        case .ready: "conversationReady"
        case .connecting: "conversationConnecting"
        case .listening: "conversationListening"
        case .processing: "conversationProcessing"
        case .speaking: "conversationSpeaking"
        case .paused: "conversationPaused"
        case .complete: "conversationComplete"
        }
    }

    init() {
        audio.onFailure = { [weak self] in self?.pause(notice: "voiceUnavailable") }
        live.onEchoCancellationUnavailable = { [weak self] in self?.noticeKey = "headphonesRecommended" }
        live.onInterruption = { [weak self] in self?.model?.voiceIntakeComplete = false }
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
        noticeKey = nil; textOnly = false; replyAudio = nil; phase = .connecting
        let current = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // This voice surface is Gemini Live only. Request its constrained
                // session directly: no legacy engine discovery or HTTP-turn fallback.
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

    func interrupt() {
        guard phase == .speaking else { return }
        if !live.interrupt() { stop() }
    }

    func stop(clearReply: Bool = false) {
        generation += 1
        task?.cancel(); task = nil
        live.stop()
        audio.clear()
        phase = model?.voiceIntakeComplete == true ? .complete : .paused
        if clearReply { replyAudio = nil }
    }

    private var permitted: Bool {
        model?.voiceConsent == true && app?.connected == true && app?.simulateOffline == false && app?.session != nil
    }

    private func pause(notice: String) {
        stop(); noticeKey = notice
    }

    private func playbackFinished() {
        model?.lastActivity = Date()
        phase = model?.voiceIntakeComplete == true ? .complete : .paused
    }
}
