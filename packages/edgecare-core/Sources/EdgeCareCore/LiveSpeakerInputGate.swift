import Foundation

/// Intentional turn-taking: never send the loudspeaker's speech back as patient
/// input. Capture may stay running locally, but playback and its acoustic tail
/// are excluded before onset detection, pre-roll, or network transmission.
public struct LiveSpeakerInputGate: Sendable {
    private var playing = false
    private var waitingForTail = false
    private var acceptAfter = -Double.infinity
    public var isHoldingInput: Bool { playing || waitingForTail }
    public init() {}

    public mutating func beganPlayback() {
        playing = true
        waitingForTail = false
    }

    public mutating func endedPlayback(at time: TimeInterval) {
        guard playing, time.isFinite else { return }
        playing = false
        waitingForTail = true
        acceptAfter = time + 0.5
    }

    /// Keep the cutoff after rearming so delayed capture callbacks cannot deliver
    /// old echo into a newly opened microphone stream.
    public mutating func rearm(at time: TimeInterval) -> Bool {
        guard !playing, waitingForTail, time >= acceptAfter else { return false }
        waitingForTail = false
        return true
    }

    public func allowsInput(capturedAt time: TimeInterval, duration: TimeInterval) -> Bool {
        !isHoldingInput && time.isFinite && duration.isFinite && duration > 0 &&
            time - duration >= acceptAfter
    }
}
