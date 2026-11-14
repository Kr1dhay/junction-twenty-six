/// Bounds automatic listening independently of UI and audio playback callbacks.
public struct VoiceConversationLoop: Sendable {
    public private(set) var isRunning = false
    public private(set) var reachedTurnLimit = false
    public private(set) var turns = 0
    private let turnLimit: Int
    public init(turnLimit: Int = 6) { self.turnLimit = max(1, turnLimit) }
    public mutating func start() { isRunning = true; reachedTurnLimit = false; turns = 0 }
    public mutating func stop() { isRunning = false }
    public mutating func receivedResponse(conversationEnded: Bool, speechAvailable: Bool) {
        guard isRunning else { return }
        turns += 1
        if conversationEnded || !speechAvailable { isRunning = false; return }
        if turns >= turnLimit { reachedTurnLimit = true; isRunning = false }
    }
}
