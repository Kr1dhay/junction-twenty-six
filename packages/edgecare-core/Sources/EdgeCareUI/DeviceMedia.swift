import SwiftUI
import Foundation
import EdgeCareCore
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif
#if os(iOS)
@preconcurrency import AVFoundation
@preconcurrency import Speech
import UIKit
import PhotosUI
#endif

@MainActor final class SpeechController: NSObject, ObservableObject {
    @Published var listening = false
    @Published var unavailable = false
    @Published private(set) var speaking = false
    @Published private(set) var playbackStarted = false
    private var generation = 0
    #if os(iOS)
    private var engine: AVAudioEngine?
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let speaker = AVSpeechSynthesizer()
    private var utteranceID: ObjectIdentifier?
    private var ownsAudioSession = false
    private var synthesisWatchdog: Task<Void, Never>?
    #endif
    override init() {
        super.init()
        #if os(iOS)
        speaker.delegate = self
        #endif
    }
    func speak(_ text: String, language: String) {
        #if os(iOS)
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let prefix = String(language.lowercased().prefix(2))
        guard let voice = AVSpeechSynthesisVoice(language: Self.locale(language)) ??
                AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.lowercased().hasPrefix(prefix) })
        else { unavailable = true; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            ownsAudioSession = true
        } catch { unavailable = true; return }
        unavailable = false; speaking = true
        let utterance = AVSpeechUtterance(string: text)
        utteranceID = ObjectIdentifier(utterance)
        utterance.voice = voice
        utterance.rate = 0.45
        speaker.usesApplicationAudioSession = true
        speaker.speak(utterance)
        let current = generation
        synthesisWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.generation == current else { return }
            // Missing/download-pending simulator voices can queue without starting.
            self.stop(); self.unavailable = true
        }
        #else
        unavailable = true
        #endif
    }
    static func locale(_ language: String) -> String {
        ["en": "en-GB", "fi": "fi-FI", "so": "so-SO", "ar": "ar-SA", "uk": "uk-UA", "ne": "ne-NP"][String(language.lowercased().prefix(2))] ?? language
    }
    func start(language: String, onText: @escaping @MainActor @Sendable (String) -> Void) async {
        #if os(iOS)
        stop(); unavailable = false
        let run = generation
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Self.locale(language))), recognizer.supportsOnDeviceRecognition else { unavailable = true; return }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard generation == run else { return }
        guard status == .authorized else { unavailable = true; return }
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard generation == run else { return }
        guard allowed else { unavailable = true; return }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true)
            let audioEngine = AVAudioEngine()
            let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            recognitionRequest.requiresOnDeviceRecognition = true
            recognitionRequest.shouldReportPartialResults = true
            let input = audioEngine.inputNode
            let tapRequest = AudioThreadBox(value: recognitionRequest)
            input.installRealtimeTap(bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer in tapRequest.value.append(buffer) }
            engine = audioEngine; request = recognitionRequest
            task = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let finished = result?.isFinal == true || error != nil
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard self?.generation == run else { return }
                    if let text { onText(text) }
                    if finished { self?.stop() }
                    if failed { self?.unavailable = true }
                }
            }
            audioEngine.prepare(); try audioEngine.start(); listening = true
        } catch { stop(); unavailable = true }
        #else
        unavailable = true
        #endif
    }
    func stop() {
        generation += 1
        #if os(iOS)
        let heldAudioSession = engine != nil || ownsAudioSession
        synthesisWatchdog?.cancel(); synthesisWatchdog = nil; utteranceID = nil
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio(); task?.cancel(); engine = nil; task = nil; request = nil
        speaker.stopSpeaking(at: .immediate)
        ownsAudioSession = false
        if heldAudioSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
        listening = false; speaking = false; playbackStarted = false
    }
    #if os(iOS)
    private func synthesisStarted(id: ObjectIdentifier) {
        guard id == utteranceID else { return }
        playbackStarted = true
        synthesisWatchdog?.cancel(); synthesisWatchdog = nil
        NSLog("EdgeCare speech: read-aloud playback started")
    }
    private func synthesisEnded(id: ObjectIdentifier) {
        guard id == utteranceID else { return }
        stop()
        NSLog("EdgeCare speech: read-aloud playback ended")
    }
    #endif
}

#if os(iOS)
extension SpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.synthesisStarted(id: id) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.synthesisEnded(id: id) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.synthesisEnded(id: id) }
    }
}
#endif

func detectedLanguage(_ text: String) -> String? {
    #if canImport(NaturalLanguage)
    guard text.count >= 10 else { return nil }
    let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
    guard let language = recognizer.dominantLanguage?.rawValue,
          Copy.languages.contains(language), (recognizer.languageHypotheses(withMaximum: 1).values.first ?? 0) > 0.65 else { return nil }
    return language
    #else
    return nil
    #endif
}

#if os(iOS)
struct CameraCapture: UIViewControllerRepresentable {
    var completion: (Data?) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    @MainActor final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraCapture
        init(_ parent: CameraCapture) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.completion((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.85)); parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.completion(nil); parent.dismiss() }
    }
}


struct EvidenceCapture: View {
    let language: String
    @Binding var letterText: String
    @Binding var lesionPresent: Bool
    @State private var selection: PhotosPickerItem?
    @State private var isLetter = true
    @State private var camera = false
    @State private var busy = false
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Copy.text("optional", language)).foregroundStyle(.secondary)
            Picker(Copy.text("evidence", language), selection: $isLetter) {
                Text(Copy.text("letter", language)).tag(true)
                Text(Copy.text("lesion", language)).tag(false)
            }.pickerStyle(.menu)
            HStack {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { camera = true } label: { Label(Copy.text("camera", language), systemImage: "camera") }.buttonStyle(.edgeCareSecondary)
                }
                PhotosPicker(selection: $selection, matching: .images) {
                    Label(Copy.text("photos", language), systemImage: "photo")
                }.buttonStyle(.edgeCareSecondary)
            }.disabled(busy)
            if busy { ProgressView(Copy.text("saving", language)) }
            if let message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
            if isLetter || !letterText.isEmpty {
                if !letterText.isEmpty { Text(Copy.text("ocr", language)).font(.subheadline) }
                TextEditor(text: $letterText).frame(minHeight: 130).scrollContentBackground(.hidden).padding(8)
                    .background(EdgeCareStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(EdgeCareStyle.hairline))
                if !letterText.isEmpty {
                    Button(Copy.text("remove", language), role: .destructive) { letterText = "" }
                }
            }
            if lesionPresent {
                Label(Copy.text("photoAdded", language), systemImage: "checkmark.circle")
                Button(Copy.text("remove", language), role: .destructive) { lesionPresent = false }
            }
            if !isLetter || lesionPresent {
                Text(Copy.text("vision", language)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $camera) { CameraCapture { data in if let data { operation = Task { await process(data) } } }.ignoresSafeArea() }
        .onChange(of: selection) { _, item in
            let forLetter = isLetter
            operation?.cancel()
            operation = Task {
                if let data = try? await item?.loadTransferable(type: Data.self), !Task.isCancelled { await process(data, letter: forLetter) }
                selection = nil
            }
        }
        .onDisappear { operation?.cancel(); operation = nil }
    }
    @MainActor private func process(_ data: Data, letter: Bool? = nil) async {
        guard !data.isEmpty, data.count <= 30_000_000 else { message = Copy.text("error", language); return }
        if letter ?? isLetter {
            busy = true; defer { busy = false }
            do {
                let text = try await AppleVisionOCREngine().interpret(image: data)
                guard !Task.isCancelled else { return }
                if text.isEmpty { message = Copy.text("error", language) } else { letterText = String(text.prefix(6000)); message = nil }
            } catch { message = Copy.text("error", language) }
        } else { guard !Task.isCancelled else { return }; lesionPresent = true; message = nil }
    }
}
#else
struct EvidenceCapture: View {
    let language: String
    @Binding var letterText: String
    @Binding var lesionPresent: Bool
    var body: some View {
        VStack(alignment: .leading) {
            Text(Copy.text("optional", language))
            TextEditor(text: $letterText).frame(minHeight: 130)
            Toggle(Copy.text("lesion", language), isOn: $lesionPresent)
            Text(Copy.text("vision", language)).font(.subheadline)
        }
    }
}
#endif
