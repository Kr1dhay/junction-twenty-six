import SwiftUI
import Combine
import EdgeCareCore
#if os(iOS)
@preconcurrency import AVFoundation
#endif

/// Recording and playback are mutually exclusive. Only a successful playback
/// completion may hand control back to the conversation's listening loop.
@MainActor final class ConversationAudio: NSObject {
    var onTurn: ((Data) -> Void)?
    var onSilence: (() -> Void)?
    var onFailure: (() -> Void)?
    var onPlaybackFinished: (() -> Void)?
    var onListening: (() -> Void)?
    var onActivity: (() -> Void)?
    private var generation = 0
    private var meterTask: Task<Void, Never>?
    #if os(iOS)
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var file: URL?
    private var interruption: AnyCancellable?
    private var routeChange: AnyCancellable?
    private var activeSince = ContinuousClock.now
    #endif

    override init() {
        super.init()
        #if os(iOS)
        interruption = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).sink { @Sendable [weak self] notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            let occurred = ContinuousClock.now
            Task { @MainActor [weak self] in self?.interrupted(at: occurred) }
        }
        routeChange = NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).sink { @Sendable [weak self] notification in
            guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            let occurred = ContinuousClock.now
            Task { @MainActor [weak self] in self?.interrupted(at: occurred) }
        }
        #endif
    }

    func listen() async -> Bool {
        clear()
        let current = generation
        #if os(iOS)
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { @Sendable in continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled, current == generation else { return false }
        guard allowed else { return false }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
            file = url
            let recording = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22050, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
            recording.isMeteringEnabled = true
            recording.delegate = self
            guard recording.record() else { throw CoreError.notConfigured }
            recorder = recording
            activeSince = ContinuousClock.now
            onListening?()
            meterTask = Task { [weak self] in
                var detector = AdaptiveSpeechActivity()
                var hasSpeech = false
                var lastSample: TimeInterval = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self, self.generation == current, let recorder = self.recorder else { return }
                    guard recorder.isRecording else { self.fail(); return }
                    recorder.updateMeters()
                    let power = recorder.averagePower(forChannel: 0), time = recorder.currentTime
                    let result = detector.sample(power: power, duration: min(0.25, time - lastSample))
                    lastSample = time
                    if result.speechDetected { hasSpeech = true; self.onActivity?() }
                    if result.speechEnded || (hasSpeech && time >= 30) {
                        guard let data = self.takeRecording() else { self.fail(); return }
                        self.onTurn?(data)
                        return
                    }
                    if !hasSpeech && time >= 12 {
                        self.clear()
                        self.onSilence?()
                        return
                    }
                }
            }
            return true
        } catch { clear(); return false }
        #else
        return false
        #endif
    }

    func play(_ base64: String) -> Bool {
        clear()
        #if os(iOS)
        guard let data = Data(base64Encoded: base64) else { return false }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let playback = try AVAudioPlayer(data: data)
            playback.delegate = self
            player = playback
            activeSince = ContinuousClock.now
            guard playback.play() else { clear(); return false }
            return true
        } catch { clear(); return false }
        #else
        return false
        #endif
    }

    func clear() {
        generation += 1
        meterTask?.cancel(); meterTask = nil
        #if os(iOS)
        let heldSession = recorder != nil || player != nil
        recorder?.delegate = nil; player?.delegate = nil
        recorder?.stop(); player?.stop(); recorder = nil; player = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        if heldSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
    }

    private func fail() { clear(); onFailure?() }

    #if os(iOS)
    private func interrupted(at occurred: ContinuousClock.Instant) {
        guard occurred >= activeSince, recorder != nil || player != nil else { return }
        fail()
    }
    private func takeRecording() -> Data? {
        recorder?.delegate = nil
        recorder?.stop()
        let data = file.flatMap { try? Data(contentsOf: $0) }
        clear()
        return data?.isEmpty == false ? data : nil
    }
    private func playbackEnded(id: ObjectIdentifier, success: Bool) {
        guard let player, ObjectIdentifier(player) == id else { return }
        clear()
        if success { onPlaybackFinished?() } else { onFailure?() }
    }
    private func recordingFailed(id: ObjectIdentifier) {
        guard let recorder, ObjectIdentifier(recorder) == id else { return }
        fail()
    }
    #endif
}

#if os(iOS)
extension ConversationAudio: AVAudioPlayerDelegate, AVAudioRecorderDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.playbackEnded(id: id, success: flag) }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.playbackEnded(id: id, success: false) }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in self?.recordingFailed(id: id) }
    }
}
#endif
