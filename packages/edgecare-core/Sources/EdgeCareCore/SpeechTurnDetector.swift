import Foundation

/// Local audio-level endpointing. Silence is never uploaded as a patient turn.
/// This detects pauses, not words or language; transcription remains server-side.
public struct SpeechTurnDetector: Sendable {
    public enum Result: Equatable, Sendable { case listening, speechEnded, noSpeech }
    public private(set) var hasSpeech = false
    private var voicedDuration: TimeInterval = 0
    private var lastSample: TimeInterval = 0
    private var lastVoice: TimeInterval = 0
    private let threshold: Float
    private let silenceDuration: TimeInterval
    private let waitingLimit: TimeInterval
    private let recordingLimit: TimeInterval

    public init(threshold: Float = -42, silenceDuration: TimeInterval = 1.5,
                waitingLimit: TimeInterval = 12, recordingLimit: TimeInterval = 30) {
        self.threshold = threshold; self.silenceDuration = silenceDuration
        self.waitingLimit = waitingLimit; self.recordingLimit = recordingLimit
    }

    public mutating func sample(power: Float, elapsed: TimeInterval) -> Result {
        guard elapsed.isFinite, elapsed >= lastSample else { return .listening }
        let interval = min(elapsed - lastSample, 0.25)
        lastSample = elapsed
        if power.isFinite && power >= threshold {
            if elapsed - lastVoice > 0.4 && !hasSpeech { voicedDuration = 0 }
            voicedDuration += interval
            lastVoice = elapsed
            if voicedDuration >= 0.3 { hasSpeech = true }
        }
        if hasSpeech && (elapsed - lastVoice >= silenceDuration || elapsed >= recordingLimit) { return .speechEnded }
        if !hasSpeech && elapsed >= waitingLimit { return .noSpeech }
        return .listening
    }
}
