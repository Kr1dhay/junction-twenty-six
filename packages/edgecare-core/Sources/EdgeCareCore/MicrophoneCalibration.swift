import Foundation

/// A short, explicit quiet interval measures this microphone's ambient level.
/// Nothing is persisted or inferred about the patient's words or language.
public struct MicrophoneCalibration: Sendable {
    public private(set) var isComplete = false
    public private(set) var noiseFloor: Float = -80
    public var speechThreshold: Float { max(-60, noiseFloor + 10) }
    public var isNoisy: Bool { isComplete && noiseFloor > -30 }
    private var samples: [(power: Float, duration: TimeInterval)] = []
    private var duration: TimeInterval = 0
    public init() {}

    public mutating func sample(power: Float, duration interval: TimeInterval) {
        guard !isComplete, power.isFinite, interval.isFinite, interval > 0 else { return }
        let interval = min(interval, 0.25)
        samples.append((max(-100, min(0, power)), interval)); duration += interval
        guard duration >= 0.8, samples.count >= 4 else { return }
        // A lower weighted percentile ignores brief clicks and speech at the end
        // of calibration without treating one unusually quiet frame as the floor.
        var accumulated: TimeInterval = 0
        for sample in samples.sorted(by: { $0.power < $1.power }) {
            accumulated += sample.duration
            if accumulated >= duration * 0.3 { noiseFloor = sample.power; break }
        }
        isComplete = true; samples = []
    }
}

/// Keeps Gemini's automatic VAD, but feeds it calibrated input instead of room
/// noise and speaker echo. The first syllable is retained in a bounded pre-roll.
public struct CalibratedMicrophoneInput: Sendable {
    public struct Frame: Sendable {
        public let audio: Data
        public let speechDetected: Bool
        public let calibrationCompleted: Bool
    }
    public private(set) var calibration = MicrophoneCalibration()
    private var preRoll = Data()
    private var onset: TimeInterval = 0
    private var hold: TimeInterval = 0
    private var open = false
    public init() {}

    public mutating func process(_ data: Data, power: Float, suppress: Bool = false) -> Frame? {
        guard !data.isEmpty, data.count.isMultiple(of: 2), data.count <= 32 * 1024 else { return nil }
        let duration = Double(data.count) / 32000
        let silence = Data(repeating: 0, count: data.count)
        if suppress {
            clearSpeech()
            // Playback is not an ambient sample and must never train the floor.
            return Frame(audio: silence, speechDetected: false, calibrationCompleted: false)
        }
        guard power.isFinite else {
            clearSpeech()
            return Frame(audio: silence, speechDetected: false, calibrationCompleted: false)
        }
        guard calibration.isComplete else {
            calibration.sample(power: power, duration: duration)
            return Frame(audio: silence, speechDetected: false, calibrationCompleted: calibration.isComplete)
        }
        let voiced = power.isFinite && power >= calibration.speechThreshold - (open ? 5 : 0)
        if open {
            if voiced { hold = 0.2 }
            else { hold = max(0, hold - duration) }
            if hold > 0 { return Frame(audio: data, speechDetected: voiced, calibrationCompleted: false) }
            clearSpeech()
        }
        preRoll.append(data)
        // 300 ms of 16 kHz mono PCM, even if a device delivers irregular buffers.
        if preRoll.count > 9600 { preRoll = Data(preRoll.suffix(9600)) }
        onset = voiced ? onset + duration : 0
        if onset >= 0.1 {
            open = true; hold = 0.2; onset = 0
            let audio = preRoll; preRoll = Data()
            return Frame(audio: audio, speechDetected: true, calibrationCompleted: false)
        }
        return Frame(audio: silence, speechDetected: false, calibrationCompleted: false)
    }
    private mutating func clearSpeech() { preRoll = Data(); onset = 0; hold = 0; open = false }
}
