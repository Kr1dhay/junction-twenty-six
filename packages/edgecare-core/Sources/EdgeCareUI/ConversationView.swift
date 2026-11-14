import SwiftUI
import EdgeCareCore
#if os(iOS)
@preconcurrency import AVFoundation
#endif

@MainActor final class ConversationAudio: ObservableObject {
    @Published var recording = false
    @Published var permissionDenied = false
    @Published var ready = false
    private var limitTask: Task<Void, Never>?
    #if os(iOS)
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var file: URL?
    #endif
    func start() async {
        #if os(iOS)
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return }
        guard allowed else { permissionDenied = true; return }
        clear()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
            file = url
            let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22050, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
            guard recorder.record(forDuration: 30) else { throw CoreError.notConfigured }
            self.recorder = recorder; recording = true; permissionDenied = false
            limitTask = Task {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                recorder.stop(); recording = false; ready = true
            }
        } catch { clear(); permissionDenied = true }
        #else
        permissionDenied = true
        #endif
    }
    func finish() -> Data? {
        #if os(iOS)
        limitTask?.cancel(); limitTask = nil
        recorder?.stop(); recording = false; ready = false
        guard let file else { return nil }
        let data = try? Data(contentsOf: file)
        try? FileManager.default.removeItem(at: file)
        self.file = nil; recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return data
        #else
        return nil
        #endif
    }
    func play(_ base64: String) {
        #if os(iOS)
        guard let data = Data(base64Encoded: base64) else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            player = try AVAudioPlayer(data: data)
            player?.play()
        } catch { permissionDenied = true }
        #endif
    }
    func clear() {
        limitTask?.cancel(); limitTask = nil; ready = false
        #if os(iOS)
        recorder?.stop(); player?.stop(); recorder = nil; player = nil
        if let file { try? FileManager.default.removeItem(at: file) }; file = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        recording = false
    }
}

struct ConversationView: View {
    @Bindable var model: IntakeViewModel
    @Bindable var app: AppSession
    @StateObject private var audio = ConversationAudio()
    @State private var typedTurn = ""
    @State private var busy = false
    @State private var unavailable = false
    @State private var languageUncertain = false
    @State private var textOnly = false
    @State private var task: Task<Void, Never>?
    @State private var replyAudio: String?
    @Environment(\.scenePhase) private var scenePhase
    private func t(_ key: String) -> String { Copy.text(key, model.language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("voiceDescription"))
            Text(t("cloudDisclosure")).font(.subheadline).foregroundStyle(.secondary)
            Toggle(t("cloudConsent"), isOn: $model.voiceConsent)
                .onChange(of: model.voiceConsent) { _, consent in if !consent { task?.cancel(); audio.clear() } }
            if !app.connected || app.simulateOffline {
                Label(t("voiceUnavailable"), systemImage: "wifi.slash")
            } else {
                ForEach(Array(model.voiceHistory.enumerated()), id: \.offset) { _, turn in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(turn.role == "assistant" ? "Edge-Care" : t("you")).font(.caption.weight(.semibold)).foregroundStyle(EdgeCareStyle.mulberry)
                        Text(turn.text).textSelection(.enabled)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                TextField(t("turnHint"), text: $typedTurn, axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder)
                HStack {
                    Button {
                        if audio.recording || audio.ready {
                            let data = audio.finish()
                            if let data { submit(audioData: data) }
                        } else { task = Task { await audio.start() } }
                    } label: { Label(t(audio.recording || audio.ready ? "sendRecording" : "recordTurn"), systemImage: audio.recording || audio.ready ? "stop.circle.fill" : "mic.circle") }
                        .buttonStyle(.borderedProminent).tint(EdgeCareStyle.mulberry)
                    Button(t("sendText")) { submit(audioData: nil) }.buttonStyle(.bordered)
                        .disabled(typedTurn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || audio.recording || audio.ready)
                }.disabled(!model.voiceConsent || busy || app.session == nil)
                if let replyAudio {
                    Button { audio.play(replyAudio) } label: { Label(t("replay"), systemImage: "play.circle") }.frame(minHeight: 48)
                }
            }
            if busy { ProgressView(t("saving")) }
            if unavailable || audio.permissionDenied { Text(t(languageUncertain ? "languageUncertain" : "voiceUnavailable")).foregroundStyle(.secondary) }
            if textOnly { Text(t("textOnly")).font(.footnote).foregroundStyle(.secondary) }
            if !model.voiceHistory.isEmpty {
                Text(t("profileReview")).font(.headline)
                Text(t("englishProfile")).font(.footnote).foregroundStyle(.secondary)
                LabeledContent(t("profileConcern")) { Text(model.clinicalProfile.concernEnglish).textSelection(.enabled) }
                LabeledContent(t("profileSymptoms")) { Text(model.clinicalProfile.symptomsEnglish.joined(separator: ", ")).textSelection(.enabled) }
                LabeledContent(t("profileDuration")) { Text(model.clinicalProfile.durationEnglish).textSelection(.enabled) }
                LabeledContent(t("profileContext")) { Text(model.clinicalProfile.additionalContextEnglish).textSelection(.enabled) }
                Text(t("profileUpdateHint")).font(.footnote)
            }
            Button(t("useForm")) { model.inputMode = "form" }.frame(minHeight: 48)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { task?.cancel(); audio.clear(); replyAudio = nil }
        }
        .onDisappear { task?.cancel(); audio.clear(); replyAudio = nil }
    }
    private func submit(audioData: Data?) {
        guard model.voiceConsent, let session = app.session else { return }
        task?.cancel(); busy = true; unavailable = false; languageUncertain = false; textOnly = false
        let submittedText = typedTurn.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedProfile = model.clinicalProfile, submittedHistory = Array(model.voiceHistory.suffix(30))
        task = Task {
            defer { busy = false }
            do {
                let response = try await session.voiceTurn(audio: audioData, mimeType: "audio/mp4", text: audioData == nil ? submittedText : nil, language: model.languageChosen ? model.language : nil, profile: submittedProfile, history: submittedHistory, consent: true)
                guard !Task.isCancelled, model.voiceConsent else { return }
                model.language = response.detectedLanguage; model.languageChosen = true
                model.voiceHistory.append(VoiceConversationTurn(role: "user", text: response.transcript))
                model.voiceHistory.append(VoiceConversationTurn(role: "assistant", text: response.reply))
                model.clinicalProfile = response.profile
                model.concern = response.profile.concernEnglish
                model.lastActivity = Date(); typedTurn = ""
                replyAudio = response.audioBase64
                if let data = response.audioBase64 { audio.play(data) }
                textOnly = !response.speechAvailable
            } catch {
                if !Task.isCancelled { unavailable = true; languageUncertain = (error as? CoreError) == .languageUncertain }
            }
        }
    }
}

struct StructuredConcernForm: View {
    @Bindable var model: IntakeViewModel
    private func t(_ key: String) -> String { Copy.text(key, model.language) }
    static let englishSymptoms = ["skin_change": "New or changing skin lesion", "lump": "New lump or swelling", "unexplained_bleeding": "Unexplained bleeding", "persistent_cough": "Persistent cough", "screening_letter": "Help understanding a screening letter", "other_concern": "Other health concern"]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("symptomQuestion")).font(.headline)
            ForEach(["skin_change", "lump", "unexplained_bleeding", "persistent_cough", "screening_letter", "other_concern"], id: \.self) { symptom in
                Toggle(t(symptom), isOn: Binding(get: { model.selectedSymptoms.contains(symptom) }, set: { selected in
                    if selected { model.selectedSymptoms.insert(symptom) } else { model.selectedSymptoms.remove(symptom) }
                    updateProfile()
                })).frame(minHeight: 44)
            }
            Picker(t("profileDuration"), selection: $model.duration) {
                Text(t("unsure")).tag("unknown")
                Text(t("shortDuration")).tag("less_than_three_weeks")
                Text(t("longDuration")).tag("three_weeks_or_longer")
            }.pickerStyle(.menu).onChange(of: model.duration) { _, _ in updateProfile() }
            Picker(t("severity"), selection: $model.severity) {
                Text(t("unsure")).tag("unknown")
                Text(t("mild")).tag("mild")
                Text(t("moderate")).tag("moderate")
                Text(t("severe")).tag("severe")
            }.pickerStyle(.menu).onChange(of: model.severity) { _, _ in updateProfile() }
            TextField(t("optionalNotes"), text: $model.concern, axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder)
            Text(t("formProfileHint")).font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func updateProfile() {
        let symptoms = model.selectedSymptoms.sorted().compactMap { Self.englishSymptoms[$0] }
        model.clinicalProfile = ClinicalProfile(concernEnglish: symptoms.joined(separator: "; "), symptomsEnglish: symptoms, durationEnglish: ["unknown": "Not sure", "less_than_three_weeks": "Less than three weeks", "three_weeks_or_longer": "Three weeks or longer"][model.duration] ?? "Not sure", additionalContextEnglish: "Reported severity: \(model.severity). Structured, patient-selected intake; clinician review required.")
        model.lastActivity = Date()
    }
}
