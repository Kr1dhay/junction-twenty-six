import Foundation
import Combine
import os
import EdgeCareCore
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

/// Input level shared between the audio thread and the main actor. Lets the controller tell
/// "nobody is talking" apart from "the microphone delivers digital silence" (for example a
/// Simulator whose Mac input is muted or not permitted), and detect a stalled engine.
final class MicLevel: Sendable {
    private struct State { var peak: Float = 0; var buffers = 0; var nonZero = 0 }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Gated buffers (translated speech playing, or paused) count as alive but not as silent:
    /// echo cancellation legitimately zeroes the input while the speaker is talking.
    func record(peak: Float, gated: Bool = false) {
        state.withLock { $0.buffers += 1; if gated { $0.nonZero += 1; return }; $0.peak = max($0.peak, peak); if peak > 0 { $0.nonZero += 1 } }
    }
    /// Returns and resets the window: peak level (0...1), buffers seen, and buffers with any signal.
    func drain() -> (peak: Float, buffers: Int, nonZero: Int) {
        state.withLock { current in
            defer { current = State() }
            return (current.peak, current.buffers, current.nonZero)
        }
    }
}

/// Microphone health, reported to the clinician so a dead input never looks like "listening".
enum MicHealth: Equatable { case ok, silent, stalled }

#if os(iOS)
/// Owns the converter used on the audio thread; all access is serialized by the tap callback.
private final class TapConverter: @unchecked Sendable {
    let converter: AVAudioConverter
    let output: AVAudioFormat
    var chunker = PCMChunker()
    init?(input: AVAudioFormat) {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.converter = converter; self.output = output
    }
    static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0] else { return 1 }
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[index])) }
        return peak
    }
    func convert(_ buffer: AVAudioPCMBuffer) -> [Data] {
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
    let level = MicLevel()
    var onInterrupted: (() -> Void)?
    private var queue: [Data] = []
    private var onChunk: (@Sendable (Data) -> Void)?
    #if os(iOS)
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayer?
    private var observers: [AnyCancellable] = []
    private var configurationObserver: AnyCancellable?
    #endif
    #if DEBUG
    private var injector: Task<Void, Never>?
    private(set) var debugInjectionFinished = false
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
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            self.onChunk = onChunk
            #if DEBUG
            if let files = ProcessInfo.processInfo.environment["EDGECARE_DEBUG_AUDIO_FILE"], !files.isEmpty {
                startInjection(files.split(separator: ",").map(String.init))
                return true
            }
            #endif
            try startEngine()
            return true
        } catch {
            consultationAudioLog.error("mic start failed: \(error.localizedDescription, privacy: .public)")
            stop(); return false
        }
        #else
        return false
        #endif
    }

    #if os(iOS)
    /// Builds a fresh engine and tap. Also used to recover after a configuration change, which on
    /// Simulator routes (and on some hardware route switches) stops the engine and kills the tap.
    private func startEngine() throws {
        guard let onChunk else { throw CoreError.notConfigured }
        if let old = engine { old.inputNode.removeTap(onBus: 0); old.stop() }
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
        guard format.sampleRate > 0, format.channelCount > 0, let converter = TapConverter(input: format) else { throw CoreError.notConfigured }
        let gate = self.gate, level = self.level
        input.installRealtimeTap(bufferSize: 4096, format: format) { buffer in
            let open = gate.isOpen
            level.record(peak: TapConverter.peak(buffer), gated: !open)
            let chunks = converter.convert(buffer)
            guard open else { return }
            for chunk in chunks { onChunk(chunk) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        configurationObserver = NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange, object: engine).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.recoverEngine() }
        }
    }
    private func recoverEngine() {
        guard engine != nil else { return }
        consultationAudioLog.info("mic engine configuration changed; restarting capture")
        do { try startEngine() } catch {
            consultationAudioLog.error("mic restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif

    /// Restarts capture if the tap stopped delivering (called by the controller's watchdog).
    func restartCapture() {
        #if os(iOS)
        recoverEngine()
        #endif
    }

    #if DEBUG
    /// Simulator automation only: streams 16 kHz mono PCM16 WAV files in real time instead of the
    /// microphone, with silence between files so Scribe's VAD commits each one. Honours the gate.
    private func startInjection(_ paths: [String]) {
        guard let onChunk else { return }
        let gate = self.gate, level = self.level
        injector = Task.detached { [weak self] in
            let silence = Data(count: PCMChunker.chunkBytes)
            func feed(_ chunk: Data) async -> Bool {
                guard !Task.isCancelled else { return false }
                level.record(peak: chunk == silence ? 0.002 : 0.5, gated: !gate.isOpen)
                if gate.isOpen { onChunk(chunk) }
                try? await Task.sleep(for: .milliseconds(100))
                return true
            }
            for _ in 0..<20 { guard await feed(silence) else { return } }
            for path in paths {
                guard let wav = try? Data(contentsOf: URL(fileURLWithPath: path)), let marker = wav.range(of: Data("data".utf8)) else {
                    consultationAudioLog.error("inject: cannot read \(path, privacy: .public)"); continue
                }
                let pcm = wav[(marker.upperBound + 4)...]
                consultationAudioLog.info("inject: \((path as NSString).lastPathComponent, privacy: .public) \(pcm.count) bytes")
                // Wait for any translated speech to finish, as a real speaker would.
                while !gate.isOpen { guard await feed(silence) else { return } }
                var offset = pcm.startIndex
                while offset < pcm.endIndex {
                    let end = min(offset + PCMChunker.chunkBytes, pcm.endIndex)
                    guard await feed(Data(pcm[offset..<end])) else { return }
                    offset = end
                }
                for _ in 0..<30 { guard await feed(silence) else { return } }
            }
            consultationAudioLog.info("inject: done")
            await MainActor.run { [weak self] in self?.debugInjectionFinished = true }
            while await feed(silence) {}
        }
    }
    #endif

    /// Plays translated speech in order. The microphone stays gated until the queue drains.
    func enqueue(_ audio: Data) {
        queue.append(audio)
        if !isPlaying, !holdPlayback { playNext() }
    }
    /// While someone is mid-sentence, translated speech waits: playing it would close the mic gate
    /// and chop off the rest of their words. Released when their utterance is committed.
    var holdPlayback = false {
        didSet { if oldValue, !holdPlayback, !isPlaying, !queue.isEmpty { playNext() } }
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
        if holdPlayback, !queue.isEmpty { gate.setPlaying(false); return }
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
        onChunk = nil
        #if DEBUG
        injector?.cancel(); injector = nil
        #endif
        #if os(iOS)
        configurationObserver = nil
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
