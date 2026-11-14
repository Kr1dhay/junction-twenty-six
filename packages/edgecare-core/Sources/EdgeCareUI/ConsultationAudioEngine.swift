import Foundation
import Combine
import os
#if os(iOS)
@preconcurrency import AVFoundation
#endif

/// Thread-safe gate read from the real-time audio thread. While closed, microphone audio is
/// dropped so translated speech coming out of the speaker is never transcribed again.
final class MicGate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (playing: false, paused: false))
    var isOpen: Bool { state.withLock { !$0.playing && !$0.paused } }
    func setPlaying(_ value: Bool) { state.withLock { $0.playing = value } }
    func setPaused(_ value: Bool) { state.withLock { $0.paused = value } }
}

/// Accumulates PCM16 bytes into ~100 ms chunks (3,200 bytes at 16 kHz mono), as both realtime APIs recommend.
struct PCMChunker: Sendable {
    static let chunkBytes = 3200
    private var buffer = Data()
    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var chunks: [Data] = []
        while buffer.count >= Self.chunkBytes {
            chunks.append(buffer.prefix(Self.chunkBytes)); buffer.removeFirst(Self.chunkBytes)
        }
        return chunks
    }
    mutating func reset() { buffer.removeAll(keepingCapacity: true) }
}

#if os(iOS)
/// Owns the converter used on the audio thread; all access is serialized by the tap callback.
private final class TapConverter: @unchecked Sendable {
    let converter: AVAudioConverter
    let output: AVAudioFormat
    var chunker = PCMChunker()
    #if DEBUG
    private var debugPeak: Float = 0
    private var debugBuffers = 0
    #endif
    init?(input: AVAudioFormat) {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.converter = converter; self.output = output
    }
    func convert(_ buffer: AVAudioPCMBuffer) -> [Data] {
        #if DEBUG
        // Diagnostics only: a peak near 0 means the microphone is delivering silence.
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<Int(buffer.frameLength) { debugPeak = max(debugPeak, abs(samples[index])) }
        }
        debugBuffers += 1
        if debugBuffers % 20 == 0 {
            consultationAudioLog.debug("mic peak \(self.debugPeak, format: .fixed(precision: 4)) over \(20) buffers")
            debugPeak = 0
        }
        #endif
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true; outStatus.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil, converted.frameLength > 0, let samples = converted.int16ChannelData else { return [] }
        let data = Data(bytes: samples[0], count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
        return chunker.append(data)
    }
}
#endif

let consultationAudioLog = Logger(subsystem: "org.edgecare.consultation", category: "audio")

@MainActor final class ConsultationAudioEngine: NSObject {
    let gate = MicGate()
    var onInterrupted: (() -> Void)?
    private var queue: [Data] = []
    #if os(iOS)
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayer?
    private var observers: [AnyCancellable] = []
    #endif

    override init() {
        super.init()
        #if os(iOS)
        observers.append(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).sink { [weak self] notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in self?.onInterrupted?() }
        })
        observers.append(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).sink { [weak self] notification in
            guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor [weak self] in self?.onInterrupted?() }
        })
        #endif
    }

    /// Starts the microphone. `onChunk` is called off the main thread with ~100 ms of PCM16 audio.
    func start(onChunk: @escaping @Sendable (Data) -> Void) async -> Bool {
        stop()
        #if os(iOS)
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard allowed else { return false }
        do {
            let session = AVAudioSession.sharedInstance()
            // voiceChat enables Apple's echo cancellation on top of the playback gate.
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            #if targetEnvironment(simulator)
            // The simulator's voice-processing unit delivers silence from the Mac microphone,
            // so nothing would ever be transcribed. Real devices keep echo cancellation.
            #else
            try? input.setVoiceProcessingEnabled(true)
            #endif
            let format = input.outputFormat(forBus: 0)
            consultationAudioLog.info("mic input format: \(format.sampleRate, format: .fixed(precision: 0)) Hz, \(format.channelCount) ch")
            guard format.sampleRate > 0, let converter = TapConverter(input: format) else { return false }
            let gate = self.gate
            input.installRealtimeTap(bufferSize: 4096, format: format) { buffer in
                let chunks = converter.convert(buffer)
                guard gate.isOpen else { return }
                for chunk in chunks { onChunk(chunk) }
            }
            engine.prepare()
            try engine.start()
            self.engine = engine
            return true
        } catch { stop(); return false }
        #else
        return false
        #endif
    }

    /// Plays translated speech in order. The microphone stays gated until the queue drains.
    func enqueue(_ audio: Data) {
        queue.append(audio)
        if !isPlaying { playNext() }
    }
    var isPlaying: Bool {
        #if os(iOS)
        player?.isPlaying == true
        #else
        false
        #endif
    }
    func stopPlayback() {
        queue.removeAll()
        #if os(iOS)
        player?.delegate = nil; player?.stop(); player = nil
        #endif
        gate.setPlaying(false)
    }
    private func playNext() {
        #if os(iOS)
        guard !queue.isEmpty else {
            // A short tail lets the room echo die away before the microphone reopens.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, !self.isPlaying, self.queue.isEmpty else { return }
                self.gate.setPlaying(false)
            }
            return
        }
        let data = queue.removeFirst()
        gate.setPlaying(true)
        do {
            let playback = try AVAudioPlayer(data: data)
            playback.delegate = self
            player = playback
            if !playback.play() { player = nil; playNext() }
        } catch { player = nil; playNext() }
        #endif
    }
    fileprivate func finished(_ id: ObjectIdentifier) {
        #if os(iOS)
        guard let player, ObjectIdentifier(player) == id else { return }
        self.player = nil
        playNext()
        #endif
    }

    func stop() {
        stopPlayback()
        #if os(iOS)
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop(); engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

#if os(iOS)
extension ConsultationAudioEngine: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.finished(id) }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.finished(id) }
    }
}
#endif
