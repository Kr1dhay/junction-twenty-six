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
    var onAudibleDrain: (() -> Void)?
    var onFailure: (() -> Void)?
    var onCaptureFailure: (() -> Void)?
    private var generation = 0
    private var playback = LivePlaybackProgress()
    private(set) var hasEchoCancellation = false
    var queuedFrames: Int { playback.queuedFrames }
    var isAudible: Bool { playback.isAudible }
    #if os(iOS)
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var capturing = false
    private var interruption: AnyCancellable?
    private var routeChange: AnyCancellable?
    private var configurationChange: AnyCancellable?
    private var captureWatchdog: Task<Void, Never>?
    private var inputGeneration = 0
    private var wantsEngineRunning = false
    private var lastInput = ContinuousClock.now
    private var lastInputLog = ContinuousClock.now
    private var inputBuffers = 0
    private var inputPeak: Float = -100
    private var activeSince = ContinuousClock.now
    #endif

    func prepare(capture: Bool) async throws {
        stop()
        let current = generation
        #if os(iOS)
        if capture {
            let allowed = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { @Sendable in continuation.resume(returning: $0) }
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
                // Keep duplex capture working on unsupported simulator routes.
                // Headphones are recommended when hardware echo cancellation is absent.
                engine = AVAudioEngine()
            }
            hasEchoCancellation = engine.inputNode.isVoiceProcessingEnabled
        }
        self.engine = engine; self.player = player
        engine.attach(player)
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
        engine.connect(player, to: engine.mainMixerNode, format: output)
        // Do not start input I/O before the microphone tap exists. On simulator
        // routes the format can change during token provisioning and stop the
        // engine, leaving a later-installed tap attached to a stopped engine.
        engine.prepare()
        activeSince = ContinuousClock.now
        configurationChange = AudioNotificationObserver.observe(.AVAudioEngineConfigurationChange, object: engine) { [weak self] _ in
            guard let self, self.generation == current else { return }
            self.recoverConfigurationChange()
        }
        interruption = AudioNotificationObserver.observe(AVAudioSession.interruptionNotification,
            codeKey: AVAudioSessionInterruptionTypeKey) { [weak self] event in
            guard event.code == AVAudioSession.InterruptionType.began.rawValue else { return }
            self?.interrupted(at: event.occurred)
        }
        routeChange = AudioNotificationObserver.observe(AVAudioSession.routeChangeNotification,
            codeKey: AVAudioSessionRouteChangeReasonKey) { [weak self] event in
            guard event.code == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            self?.interrupted(at: event.occurred)
        }
        if !capture {
            wantsEngineRunning = true
            try engine.start()
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
        let converter = try LivePCMConverter(input: format), current = generation, capture = inputGeneration
        let deliver: @Sendable (Data, Float) -> Void = { [weak self] data, power in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, self.inputGeneration == capture, self.capturing else { return }
                self.lastInput = .now
                self.inputBuffers += 1; self.inputPeak = max(self.inputPeak, power)
                if self.lastInputLog.duration(to: .now) >= .seconds(1) {
                    NSLog("EdgeCare voice: microphone buffers=%d peak_db=%.1f", self.inputBuffers, self.inputPeak)
                    self.inputBuffers = 0; self.inputPeak = -100; self.lastInputLog = .now
                }
                self.onInput?(data, power)
            }
        }
        input.installRealtimeTap(bufferSize: 1600, format: format) { buffer in
            if let (data, power) = converter.convert(buffer) { deliver(data, power) }
        }
        capturing = true
        wantsEngineRunning = true
        lastInput = .now; lastInputLog = .now; inputBuffers = 0; inputPeak = -100
        do {
            if !engine.isRunning { engine.prepare(); try engine.start() }
            NSLog("EdgeCare voice: capture engine running=%d echo_cancellation=%d", engine.isRunning ? 1 : 0, hasEchoCancellation ? 1 : 0)
        } catch {
            stopCapture()
            throw error
        }
        captureWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.generation == current, self.inputGeneration == capture, self.capturing else { return }
                if self.lastInput.duration(to: .now) > .seconds(3) {
                    NSLog("EdgeCare voice: microphone stream stalled")
                    self.onCaptureFailure?()
                    return
                }
            }
        }
        #else
        throw CoreError.notConfigured
        #endif
    }

    func stopCapture() {
        #if os(iOS)
        inputGeneration += 1
        captureWatchdog?.cancel(); captureWatchdog = nil
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
        let chunk = playback.enqueue(frames: frames, audible: (PCM16Audio.power(data) ?? -90) > -50)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                let wasAudible = self.playback.isAudible
                guard self.playback.played(chunk) else { return }
                if wasAudible && !self.playback.isAudible { self.onAudibleDrain?() }
                if self.queuedFrames == 0 { self.onDrain?() }
            }
        }
        if !player.isPlaying { player.play() }
        #else
        throw CoreError.notConfigured
        #endif
    }

    func interruptPlayback() {
        playback.reset()
        #if os(iOS)
        player?.stop()
        // Never stop/reinstall the input tap here: doing so drops the beginning of
        // the patient's interruption and invalidates in-flight capture callbacks.
        #endif
    }

    func stop() {
        generation += 1; playback.reset(); hasEchoCancellation = false
        #if os(iOS)
        let heldSession = engine != nil
        wantsEngineRunning = false
        stopCapture(); interruption = nil; routeChange = nil; configurationChange = nil
        player?.stop(); engine?.stop(); player = nil; engine = nil
        if heldSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
    }
    #if os(iOS)
    private func recoverConfigurationChange() {
        guard wantsEngineRunning, let engine, !engine.isRunning else { return }
        let wasCapturing = capturing
        NSLog("EdgeCare voice: audio configuration stopped engine; recovering")
        do {
            if capturing {
                // The input format may have changed, so recreate only the tap and
                // converter. Normal barge-in never restarts microphone capture.
                stopCapture()
                try startCapture()
            } else {
                engine.prepare(); try engine.start()
            }
            if queuedFrames > 0, let player, !player.isPlaying { player.play() }
        } catch {
            if wasCapturing { onCaptureFailure?() } else { onFailure?() }
        }
    }
    private func interrupted(at occurred: ContinuousClock.Instant) {
        if occurred >= activeSince, engine != nil { onFailure?() }
    }
    #endif
}
