#if os(iOS)
@preconcurrency import AVFoundation

extension AVAudioNode {
    /// Installs a microphone tap whose block runs on AVAudioEngine's realtime thread.
    ///
    /// In Swift 6 a closure written inside `@MainActor` code is main-actor isolated, and the runtime
    /// traps (EXC_BREAKPOINT in `swift_task_checkIsolatedSwift`) when AVAudioEngine invokes it off the
    /// main thread. A `@Sendable` block is never actor-isolated, so it is safe on the audio thread.
    nonisolated func installRealtimeTap(onBus bus: AVAudioNodeBus = 0, bufferSize: AVAudioFrameCount, format: AVAudioFormat?,
                                        _ block: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        installTap(onBus: bus, bufferSize: bufferSize, format: format) { buffer, _ in block(buffer) }
    }
}

/// Carries an audio-thread-only object (for example a speech request) into a `@Sendable` tap block.
struct AudioThreadBox<Value>: @unchecked Sendable { let value: Value }
#endif
