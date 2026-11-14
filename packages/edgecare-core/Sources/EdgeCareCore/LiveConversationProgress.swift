import Foundation

/// Audible playback, generation completion, and microphone capture are different
/// clocks. Silent PCM queued after a question must not keep the UI "speaking".
public struct LivePlaybackProgress: Sendable {
    public struct Chunk: Sendable {
        fileprivate let frames: Int
        fileprivate let audible: Bool
        fileprivate let generation: Int
        fileprivate let id: Int
    }
    public private(set) var queuedFrames = 0
    public private(set) var audibleFrames = 0
    private var generation = 0
    private var nextID = 0
    private var pending: Set<Int> = []
    public var isAudible: Bool { audibleFrames > 0 }
    public init() {}

    public mutating func enqueue(frames: Int, audible: Bool) -> Chunk {
        precondition(frames > 0)
        nextID += 1
        pending.insert(nextID)
        queuedFrames += frames
        if audible { audibleFrames += frames }
        return Chunk(frames: frames, audible: audible, generation: generation, id: nextID)
    }
    @discardableResult public mutating func played(_ chunk: Chunk) -> Bool {
        guard chunk.generation == generation, pending.remove(chunk.id) != nil else { return false }
        queuedFrames = max(0, queuedFrames - chunk.frames)
        if chunk.audible { audibleFrames = max(0, audibleFrames - chunk.frames) }
        return true
    }
    public mutating func reset() {
        generation += 1; pending = []; queuedFrames = 0; audibleFrames = 0
    }
}

/// Playback completion from an old answer cannot consume newer patient input.
public struct LiveInputProgress: Sendable {
    private var inputRevision = 0
    private var responseRevision: Int?
    public var hasNewerInput: Bool { responseRevision.map { inputRevision > $0 } ?? false }
    public init() {}
    public mutating func heardInput() { inputRevision += 1 }
    public mutating func beganResponse() {
        if responseRevision == nil { responseRevision = inputRevision }
    }
    public mutating func endedResponse() -> Bool {
        let consumedLatestInput = responseRevision == inputRevision
        responseRevision = nil
        return consumedLatestInput
    }
    public mutating func interrupted() { responseRevision = nil }
}
