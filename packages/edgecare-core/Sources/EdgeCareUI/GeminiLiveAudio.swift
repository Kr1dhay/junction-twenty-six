import Foundation
import Combine
import EdgeCareCore
#if os(iOS)
@preconcurrency import AVFoundation

/// Used only by AVAudioEngine's serialized input tap; buffers never cross into Swift tasks.
private final class LivePCMConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private let ratio: Double
    init(input: AVAudioFormat) throws {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { throw CoreError.notConfigured }
        self.output = output; self.converter = converter; ratio = 16000 / input.sampleRate
    }
    func convert(_ input: AVAudioPCMBuffer) -> (Data, Float)? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: buffer, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard error == nil, status != .error, buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        var sum: Double = 0
        for i in 0..<count { let value = Double(samples[i]) / 32768; sum += value * value }
        let power = Float(10 * log10(max(sum / Double(count), 0.00000001)))
        return (Data(bytes: samples, count: count * 2), power)
    }
}
#endif

/// Duplex PCM capture/playback. No recording files or per-turn MP3 generation.
@MainActor final class GeminiLiveAudio {
    var onInput: ((Data, Float) -> Void)?
    var onDrain: (() -> Void)?
    var onFailure: (() -> Void)?
    private var generation = 0
    private(set) var queuedFrames = 0
    #if os(iOS)
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var capturing = false
    private var interruption: AnyCancellable?
    private var routeChange: AnyCancellable?
    private var activeSince = ContinuousClock.now
    #endif

    func prepare(capture: Bool) async throws {
        stop()
        let current = generation
        #if os(iOS)
        if capture {
            let allowed = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard allowed else { throw CoreError.notConfigured }
        }
        guard !Task.isCancelled, generation == current else { throw CancellationError() }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(capture ? .playAndRecord : .playback, mode: capture ? .voiceChat : .spokenAudio,
                                options: capture ? [.defaultToSpeaker] : [])
        try session.setActive(true)
        var engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        if capture {
            do { try engine.inputNode.setVoiceProcessingEnabled(true) }
            catch {
                // Some simulator/input routes have no Voice Processing I/O unit.
                // The calibrated input still mutes playback echo; use a fresh engine
                // rather than making microphone capture depend on this optional unit.
                engine = AVAudioEngine()
            }
        }
        self.engine = engine; self.player = player
        engine.attach(player)
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
        engine.connect(player, to: engine.mainMixerNode, format: output)
        engine.prepare(); try engine.start()
        activeSince = ContinuousClock.now
        interruption = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).sink { [weak self] event in
            guard let type = event.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            let occurred = ContinuousClock.now
            Task { @MainActor [weak self] in self?.interrupted(at: occurred) }
        }
        routeChange = NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).sink { [weak self] event in
            guard let reason = event.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            let occurred = ContinuousClock.now
            Task { @MainActor [weak self] in self?.interrupted(at: occurred) }
        }
        #else
        throw CoreError.notConfigured
        #endif
    }

    func startCapture() throws {
        #if os(iOS)
        guard let engine, !capturing else { throw CoreError.notConfigured }
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CoreError.notConfigured }
        let converter = try LivePCMConverter(input: format), current = generation
        let deliver: @Sendable (Data, Float) -> Void = { [weak self] data, power in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, self.capturing else { return }
                self.onInput?(data, power)
            }
        }
        input.installTap(onBus: 0, bufferSize: 1600, format: format) { buffer, _ in
            if let (data, power) = converter.convert(buffer) { deliver(data, power) }
        }
        capturing = true
        #else
        throw CoreError.notConfigured
        #endif
    }

    func stopCapture() {
        #if os(iOS)
        if capturing { engine?.inputNode.removeTap(onBus: 0); capturing = false }
        #endif
    }

    func enqueue(_ data: Data) throws {
        guard !data.isEmpty, data.count.isMultiple(of: 2), data.count <= 256 * 1024,
              queuedFrames + data.count / 2 <= 24000 * 30 else { throw CoreError.invalidResponse }
        #if os(iOS)
        guard let player, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)),
              let samples = buffer.floatChannelData?[0] else { throw CoreError.notConfigured }
        let frames = data.count / 2, current = generation
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { bytes in
            for i in 0..<frames { samples[i] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768 }
        }
        queuedFrames += frames
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.queuedFrames = max(0, self.queuedFrames - frames)
                if self.queuedFrames == 0 { self.onDrain?() }
            }
        }
        if !player.isPlaying { player.play() }
        #else
        throw CoreError.notConfigured
        #endif
    }

    func interruptPlayback() {
        generation += 1
        queuedFrames = 0
        #if os(iOS)
        player?.stop()
        // Capture tap generation must be renewed after interruption, without reopening permission.
        let resumeCapture = capturing
        stopCapture()
        if resumeCapture { do { try startCapture() } catch { onFailure?() } }
        #endif
    }

    func stop() {
        generation += 1; queuedFrames = 0
        #if os(iOS)
        stopCapture(); interruption = nil; routeChange = nil
        player?.stop(); engine?.stop(); player = nil; engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
    #if os(iOS)
    private func interrupted(at occurred: ContinuousClock.Instant) {
        if occurred >= activeSince, engine != nil { onFailure?() }
    }
    #endif
}
