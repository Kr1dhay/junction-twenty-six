import SwiftUI
import Combine
import EdgeCareCore
#if os(iOS)
@preconcurrency import AVFoundation
#endif

struct VoiceResearchResultView: View {
    let result: VoiceResearchAssessment
    let language: String
    private var resultKey: String {
        switch result.outcome {
        case .flagged: "voiceResearchFlagged"
        case .notFlagged: "voiceResearchNotFlagged"
        case .inconclusive: "voiceResearchInconclusive"
        }
    }
    var spokenReport: String { Copy.text(resultKey, language) + " " + Copy.text("voiceResearchFollowUp", language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(Copy.text("voiceResearchResultTitle", language), systemImage: "waveform.badge.exclamationmark").font(.headline)
            Text(Copy.text(resultKey, language))
            Text(Copy.text("voiceResearchFollowUp", language)).font(.subheadline.weight(.medium))
            Text("\(result.modelID) · \(result.modelVersion) · \(result.assessedAt)")
                .font(.caption).foregroundStyle(.secondary)
        }.edgeCareCard(padding: 16).accessibilityIdentifier("voiceResearchResult")
    }
}

struct VoiceResearchView: View {
    @Bindable var model: IntakeViewModel
    @Bindable var app: AppSession
    @StateObject private var recorder = ResearchVoiceRecorder()
    @StateObject private var speech = SpeechController()
    @State private var available = false
    @State private var checking = true
    @State private var consent = false
    @State private var processing = false
    @State private var notice: String?
    @State private var operation: Task<Void, Never>?
    @State private var revision = UUID()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.edgeCareCompactLayout) private var compact
    private func t(_ key: String) -> String { Copy.text(key, model.language) }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Button { cancel(); dismiss() } label: { Label(t("back"), systemImage: "chevron.backward").padding(.vertical, 12) }
                        .buttonStyle(.plain).accessibilityIdentifier("voiceResearchBack")
                    Spacer()
                    EdgeCareWordmark(size: 18)
                }.font(.body.weight(.semibold)).foregroundStyle(EdgeCareStyle.accent).padding(.horizontal, 24)
                Divider().overlay(EdgeCareStyle.hairline)
                ScrollView {
                    VStack(spacing: compact ? 12 : 20) {
                        Text(t("voiceResearchTitle"))
                            .font(.system(compact ? .title2 : .largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(EdgeCareStyle.graphite)
                            .multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                        if let result = model.voiceResearch {
                            VoiceResearchResultView(result: result, language: model.language)
                            Button(t(speech.speaking ? "stopReading" : "read")) {
                                if speech.speaking { speech.stop() } else { speech.speak(spokenReport(result), language: model.language) }
                            }.buttonStyle(.edgeCareSecondary)
                        } else if model.voiceResearchDecision != "declined" {
                            Text(t("voiceResearchOffer"))
                                .font(compact ? .body : .title3).multilineTextAlignment(.center)
                            if checking { ProgressView() }
                            else if !available || app.simulateOffline {
                                Label(t("voiceResearchUnavailable"), systemImage: "wifi.slash")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            } else {
                                Text(t("voiceResearchLimits")).font(.subheadline).foregroundStyle(.secondary)
                                Toggle(t("voiceResearchConsent"), isOn: $consent).disabled(recordingOrProcessing)
                                if consent {
                                    Text(t("voiceResearchTask")).font(.subheadline).foregroundStyle(.secondary)
                                    recordingControl.frame(width: compact ? 288 : nil)
                                }
                            }
                        }
                        if let notice { Label(t(notice), systemImage: "exclamationmark.bubble").font(.subheadline).foregroundStyle(.secondary) }
                        if model.voiceResearch == nil, model.voiceResearchDecision != "declined" {
                            Button(t("voiceResearchSkip")) {
                                cancel(); consent = false; model.voiceResearch = nil; model.voiceResearchDecision = "declined"
                                model.discardPreparedUpdate(); model.lastActivity = Date()
                            }.buttonStyle(.edgeCareSecondary)
                        }
                        if model.voiceResearch != nil || model.voiceResearchDecision == "declined" {
                            Button(t("next")) { dismiss() }.buttonStyle(.edgeCarePrimary)
                                .accessibilityIdentifier("voiceResearchDone")
                        }
                    }
                    .padding(compact ? 20 : 24).frame(maxWidth: 760).frame(maxWidth: .infinity)
                    .frame(minHeight: max(0, geometry.size.height - 65))
                }
            }.background(EdgeCareStyle.canvas.ignoresSafeArea())
        }
        .interactiveDismissDisabled()
        .task(id: app.session != nil && !app.simulateOffline) {
            checking = true
            do { available = try await app.session?.voiceResearchAvailability().available ?? false }
            catch { available = false }
            if !Task.isCancelled { checking = false }
        }
        .onChange(of: consent) { _, granted in if !granted { cancel(); model.voiceResearch = nil } }
        .onChange(of: app.simulateOffline) { _, offline in if offline { cancel() } }
        .onChange(of: model.concern) { _, _ in cancel(); consent = false }
        .onChange(of: model.clinicalProfile) { _, _ in cancel(); consent = false }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancel() } }
        .onDisappear { cancel() }
    }
    private func spokenReport(_ result: VoiceResearchAssessment) -> String {
        let key: String
        switch result.outcome {
        case .flagged: key = "voiceResearchFlagged"
        case .notFlagged: key = "voiceResearchNotFlagged"
        case .inconclusive: key = "voiceResearchInconclusive"
        }
        return Copy.text(key, model.language) + " " + Copy.text("voiceResearchFollowUp", model.language)
    }
    @ViewBuilder private var recordingControl: some View {
        if recorder.recording {
            VStack(spacing: 12) {
                VoiceMicrophone(symbol: "waveform", size: 192, active: true)
                Text(t("voiceResearchRecording")).font(.headline).foregroundStyle(EdgeCareStyle.accent)
            }
            Button(t("voiceResearchCancel")) { cancel() }.buttonStyle(.edgeCareSecondary)
        } else if processing {
            ZStack {
                VoiceMicrophone(symbol: "ellipsis", size: 192, active: false)
                ProgressView().controlSize(.large).offset(y: 62)
            }.accessibilityElement(children: .ignore).accessibilityLabel(t("voiceResearchProcessing"))
        } else {
            Button(action: record) {
                VStack(spacing: 8) {
                    VoiceMicrophone(symbol: "mic.fill", size: 192, active: false)
                    Text(t("voiceResearchStart")).font(.subheadline.bold()).foregroundStyle(EdgeCareStyle.accent)
                }
            }.buttonStyle(VoiceMicrophoneButtonStyle())
                .accessibilityIdentifier("voiceResearchStart")
                .accessibilityLabel(t("voiceResearchStart"))
        }
    }
    private var recordingOrProcessing: Bool { recorder.recording || processing }
    private func cancel() {
        revision = UUID(); operation?.cancel(); operation = nil
        recorder.cancel(); processing = false; speech.stop()
    }
    private func record() {
        cancel(); notice = nil
        guard consent, available, !app.simulateOffline, let session = app.session else { return }
        model.voiceResearchDecision = "accepted"; model.lastActivity = Date()
        let current = revision, profile = model.clinicalProfile, concern = model.concern
        operation = Task {
            let started = await recorder.start { data in
                guard revision == current, consent, model.clinicalProfile == profile, model.concern == concern else { return }
                guard let data else {
                    notice = "voiceResearchUnavailable"; model.voiceResearchDecision = "unavailable"
                    return
                }
                processing = true; model.lastActivity = Date()
                operation = Task {
                    defer { if revision == current { processing = false } }
                    do {
                        let result = try await session.assessResearchVoice(audio: data, consent: consent)
                        guard !Task.isCancelled, revision == current, consent,
                              model.clinicalProfile == profile, model.concern == concern else { return }
                        model.voiceResearch = result; model.voiceResearchDecision = "completed"
                        model.discardPreparedUpdate(); model.lastActivity = Date()
                    } catch {
                        if !Task.isCancelled, revision == current {
                            notice = "voiceResearchUnavailable"; model.voiceResearchDecision = "unavailable"
                        }
                    }
                }
            }
            if !started, !Task.isCancelled, revision == current { notice = "voiceResearchPermission" }
        }
    }
}

/// A separate task: never reuses echo-cancelled consultation/Gemini audio.
@MainActor private final class ResearchVoiceRecorder: NSObject, ObservableObject {
    @Published private(set) var recording = false
    private var generation = 0
    private var completion: ((Data?) -> Void)?
    #if os(iOS)
    private var recorder: AVAudioRecorder?
    private var file: URL?
    private var interruption: AnyCancellable?
    private var routeChange: AnyCancellable?
    private var ownsAudioSession = false
    #endif
    override init() {
        super.init()
        #if os(iOS)
        interruption = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.fail() }
        }
        routeChange = NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).sink { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ||
                    reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue else { return }
            Task { @MainActor [weak self] in self?.fail() }
        }
        #endif
    }
    func start(completion: @escaping (Data?) -> Void) async -> Bool {
        cancel()
        let current = generation
        #if os(iOS)
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { @Sendable in continuation.resume(returning: $0) }
        }
        guard allowed, !Task.isCancelled, generation == current else { return false }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setActive(true)
            ownsAudioSession = true
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
            file = url
            let capture = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ])
            recorder = capture; capture.delegate = self; self.completion = completion
            guard capture.record(forDuration: 6) else { cancel(); return false }
            recording = true
            return true
        } catch { cancel(); return false }
        #else
        return false
        #endif
    }
    func cancel() {
        generation += 1; recording = false; completion = nil
        #if os(iOS)
        recorder?.delegate = nil; recorder?.stop(); recorder = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        if ownsAudioSession {
            ownsAudioSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }
    #if os(iOS)
    private func fail() {
        let callback = completion
        cancel()
        callback?(nil)
    }
    private func finished(id: ObjectIdentifier, success: Bool) {
        guard let recorder, ObjectIdentifier(recorder) == id else { return }
        let callback = completion
        let data = success ? file.flatMap { try? Data(contentsOf: $0) } : nil
        cancel()
        callback?(data.flatMap { $0.count <= 512 * 1024 ? $0 : nil })
    }
    #endif
}
#if os(iOS)
extension ResearchVoiceRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in self?.finished(id: id, success: flag) }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in self?.finished(id: id, success: false) }
    }
}
#endif
