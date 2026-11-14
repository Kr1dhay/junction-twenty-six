import Foundation

/// Level-based, continuously adapting endpointing. This is not speech recognition:
/// Google still performs speech/language detection on the gated PCM stream.
/// There is no required quiet interval and no user-operated calibration step.
public struct AdaptiveSpeechActivity: Sendable {
    public struct Sample: Sendable {
        public let speechStarted: Bool
        public let speechDetected: Bool
        public let speechEnded: Bool
        public let passAudio: Bool
    }
    public private(set) var noiseFloor: Float = -36
    public var threshold: Float { max(-60, noiseFloor + 10) }
    private var background: [(Float, Double)] = []
    private var backgroundDuration = 0.0
    private var onset = 0.0
    private var quiet = 0.0
    private var active = false
    private let onsetDuration = 0.16
    private let pauseDuration = 0.7

    public init() {}

    public mutating func sample(power: Float, duration: TimeInterval, duringPlayback: Bool = false) -> Sample {
        guard power.isFinite, duration.isFinite, duration > 0, duration <= 0.5 else {
            return Sample(speechStarted: false, speechDetected: false, speechEnded: false, passAudio: false)
        }
        // Hysteresis keeps soft syllables inside an established utterance, without
        // treating low-level room sound as the continuation of that utterance.
        // Barge-in needs a slightly stronger, longer signal, not a raised voice.
        // Once a candidate starts, retain softer syllables during confirmation as
        // well as during an established utterance. Requiring every onset frame to
        // clear the higher threshold prevents ordinary speech from interrupting.
        let onsetMargin: Float = duringPlayback && !active ? 3 : 0
        let retainingSpeech = active || (duringPlayback && onset > 0)
        let voiced = power >= threshold + onsetMargin - (retainingSpeech ? 3 : 0)
        // Raising the barge-in threshold must not teach the noise estimator that
        // a moderate speech/echo burst is the permanent background floor.
        if power < threshold - (active ? 3 : 0) {
            background.append((max(-100, min(0, power)), duration))
            backgroundDuration += duration
            while backgroundDuration > 2, background.count > 1 {
                backgroundDuration -= background.removeFirst().1
            }
            var weight = 0.0
            for (level, length) in background.sorted(by: { $0.0 < $1.0 }) {
                weight += length
                if weight >= backgroundDuration * 0.3 {
                    noiseFloor = level
                    break
                }
            }
        }
        if !active {
            onset = voiced ? onset + duration : 0
            if onset + 0.000001 >= (duringPlayback ? 0.24 : onsetDuration) {
                active = true; onset = 0; quiet = 0
                return Sample(speechStarted: true, speechDetected: true, speechEnded: false, passAudio: true)
            }
            return Sample(speechStarted: false, speechDetected: false, speechEnded: false, passAudio: false)
        }
        quiet = voiced ? 0 : quiet + duration
        if quiet + 0.000001 >= pauseDuration {
            active = false; onset = 0; quiet = 0
            return Sample(speechStarted: false, speechDetected: false, speechEnded: true, passAudio: false)
        }
        return Sample(speechStarted: false, speechDetected: voiced, speechEnded: false, passAudio: voiced || quiet < 0.15)
    }
}

/// Keeps bounded pre-roll so onset confirmation does not discard the first syllable.
/// Background becomes digital silence, allowing remote automatic VAD to end a turn
/// even when the physical microphone never becomes completely quiet.
public struct AdaptiveSpeechInput: Sendable {
    public struct Frame: Sendable {
        public let audio: Data
        public let activity: AdaptiveSpeechActivity.Sample
    }
    private var detector = AdaptiveSpeechActivity()
    private var preRoll = Data()
    public init() {}
    public mutating func process(_ data: Data, power: Float, duringPlayback: Bool = false) -> Frame? {
        guard !data.isEmpty, data.count.isMultiple(of: 2), data.count <= 8000, power.isFinite else { return nil }
        let activity = detector.sample(power: power, duration: Double(data.count) / 32000, duringPlayback: duringPlayback)
        preRoll.append(data)
        if preRoll.count > 12800 { preRoll = Data(preRoll.suffix(12800)) }
        let output: Data
        if activity.speechStarted { output = preRoll; preRoll = Data() }
        else if activity.passAudio { output = data; preRoll = Data() }
        else { output = Data(repeating: 0, count: data.count) }
        return Frame(audio: output, activity: activity)
    }
}

/// Local playback stops immediately at barge-in; do not replay old buffered
/// network audio while waiting for the server to acknowledge that interruption.
public struct LiveInterruptionGate: Sendable {
    public private(set) var awaitingAcknowledgment = false
    private var pendingCancelledCompletion = false
    public init() {}
    public mutating func interrupt(awaitingServer: Bool = true) -> Bool {
        guard !awaitingAcknowledgment else { return false }
        // Playback can outlast generation. No server interruption will arrive if
        // the old turn is already complete, so do not block the next reply then.
        awaitingAcknowledgment = awaitingServer
        return true
    }
    public mutating func acknowledge() { awaitingAcknowledgment = false }
    public var acceptsOutput: Bool { !awaitingAcknowledgment }

    /// The boundary message itself can still contain old audio/tools; discard it
    /// before opening the gate for subsequent messages from the new turn.
    public mutating func discardOutput(interrupted: Bool, turnComplete: Bool, hasNewOutput: Bool = false) -> Bool {
        if interrupted {
            acknowledge()
            // Google may acknowledge interruption and then send the cancelled
            // turn's empty completion in a separate message.
            pendingCancelledCompletion = !turnComplete
            return true
        }
        if pendingCancelledCompletion {
            if hasNewOutput { pendingCancelledCompletion = false }
            else if turnComplete {
                pendingCancelledCompletion = false
                return true
            }
        }
        let discard = interrupted || awaitingAcknowledgment
        if interrupted || turnComplete { acknowledge() }
        return discard
    }
}

/// A noisy/echoing speaker route must not repeatedly restart spoken replies.
/// This is a safety bound, not an assertion that we can identify the speaker.
public struct LiveInterruptionLimiter: Sendable {
    private var interruptions: [TimeInterval] = []
    public init() {}

    public mutating func shouldPause(interruptionAt time: TimeInterval) -> Bool {
        guard time.isFinite, time >= 0 else { return false }
        interruptions.removeAll { time - $0 > 8 || $0 > time }
        interruptions.append(time)
        return interruptions.count >= 4
    }
}
