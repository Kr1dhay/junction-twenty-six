import XCTest
import EdgeCareCore
@testable import EdgeCareUI

@MainActor private final class TestLiveAudio: GeminiLiveAudioIO {
    var onInput: ((Data, Float, TimeInterval) -> Void)?
    var onDrain: (() -> Void)?
    var onAudibleDrain: (() -> Void)?
    var onFailure: (() -> Void)?
    var onCaptureFailure: (() -> Void)?
    var queuedFrames = 0
    var isAudible = false
    var hasEchoCancellation = true
    var captureStarts = 0
    var capturing = false
    var time: TimeInterval = 1000
    func prepare(capture: Bool) async throws {}
    func startCapture() throws { captureStarts += 1; capturing = true }
    func enqueue(_ data: Data) throws {
        queuedFrames += data.count / 2
        if (PCM16Audio.power(data) ?? -90) > -50 { isAudible = true }
    }
    func interruptPlayback() { queuedFrames = 0; isAudible = false }
    func stop() { interruptPlayback(); capturing = false }
    func questionEndedWithSilenceQueued() {
        isAudible = false
        queuedFrames = 48000
        onAudibleDrain?()
    }
    func answer() {
        for _ in 0..<10 { feed(Data(count: 3200), power: -32) }
        for _ in 0..<2 { feed(Data(repeating: 2, count: 3200), power: -15) }
        for _ in 0..<7 { feed(Data(count: 3200), power: -32) }
    }
    func feed(_ data: Data, power: Float, capturedAt: TimeInterval? = nil) {
        onInput?(data, power, capturedAt ?? time)
    }
    func waitForEchoTail() {
        time += 0.7
        feed(Data(count: 3200), power: -32)
    }
}

@MainActor private final class TestLiveConnection: GeminiLiveConnectionIO {
    private var pending: CheckedContinuation<GeminiLiveEvent, Error>?
    private var processed: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var closed = false
    var acknowledgments: [String] = []
    var input: [GeminiLiveInput] = []
    private var inputWaiter: CheckedContinuation<Void, Never>?
    private var expectedInputEnds = 0
    func connect(_ credentials: GeminiLiveCredentials) async throws {}
    func receive() async throws -> GeminiLiveEvent {
        processed?.resume(); processed = nil
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation {
            pending = $0
            started?.resume(); started = nil
        }
    }
    func waitForStart() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func push(_ object: [String: Any]) async throws {
        let event = try JSONDecoder().decode(GeminiLiveEvent.self, from: JSONSerialization.data(withJSONObject: object))
        guard let pending else { XCTFail("Controller stopped before next event"); return }
        self.pending = nil
        await withCheckedContinuation {
            processed = $0
            pending.resume(returning: event)
        }
    }
    func sendInput(_ input: GeminiLiveInput) async throws {
        self.input.append(input)
        if self.input.filter({ $0 == .endUtterance }).count >= expectedInputEnds {
            inputWaiter?.resume(); inputWaiter = nil
        }
    }
    func waitForInputEnds(_ count: Int) async {
        expectedInputEnds = count
        if input.filter({ $0 == .endUtterance }).count >= count { return }
        await withCheckedContinuation { inputWaiter = $0 }
    }
    func sendText(_ text: String) async throws {}
    func acknowledge(_ call: GeminiLiveEvent.Call, endSession: Bool, superseded: Bool) async throws {
        acknowledgments.append(call.id)
    }
    func close() {
        closed = true
        pending?.resume(throwing: CancellationError()); pending = nil
        processed?.resume(); processed = nil
        inputWaiter?.resume(); inputWaiter = nil
    }
}

@MainActor final class GeminiLiveControllerTests: XCTestCase {
    private func credentials() throws -> GeminiLiveCredentials {
        try JSONDecoder().decode(GeminiLiveCredentials.self, from: JSONSerialization.data(withJSONObject: [
            "token": "test-only", "model": "gemini-3.8-live", "websocket_url": "wss://unused.test",
            "setup_json": "{}", "max_session_seconds": 300
        ]))
    }
    private func profile(_ id: String) -> [String: Any] {
        ["id": id, "name": "record_intake_profile", "args": [
            "detected_language": "en", "stop_requested": false,
            "profile": ["concern_english": "Cough", "symptoms_english": ["Cough"],
                        "duration_english": "", "additional_context_english": "Synthetic test"]
        ]]
    }
    private var audioEvent: [String: Any] {
        ["serverContent": [
            "outputTranscription": ["text": "What is the main concern?"],
            "modelTurn": ["parts": [["inlineData": ["mimeType": "audio/pcm;rate=24000", "data": Data([0, 64, 0, 192]).base64EncodedString()]]]]
        ]]
    }

    func testThreeQuestionsRearmListeningAndAcceptRepeatedProfilesWithoutRestartingCapture() async throws {
        let audio = TestLiveAudio(), connection = TestLiveConnection()
        let live = GeminiLiveController(audio: audio, makeConnection: { connection }, now: { audio.time })
        var phase: ConversationController.Phase?
        var profiles = 0
        live.onPhase = { phase = $0 }
        live.onProfile = { _ in profiles += 1 }
        try await live.prepare(capture: true)
        let credentials = try credentials()
        let run = Task { try await live.run(credentials: credentials) }
        await connection.waitForStart()
        try await connection.push(["setupComplete": [:]])
        for turn in 0..<3 {
            audio.answer()
            await connection.waitForInputEnds(turn + 1)
            XCTAssertEqual(phase, .processing)
            try await connection.push(["toolCall": ["functionCalls": [profile("\(turn)-a"), profile("\(turn)-b")]]])
            try await connection.push(audioEvent)
            XCTAssertEqual(phase, .speaking)
            // No remote turnComplete yet, but the spoken question has ended.
            audio.questionEndedWithSilenceQueued()
            XCTAssertEqual(phase, .settling)
            audio.waitForEchoTail()
            XCTAssertEqual(phase, .listening)
            XCTAssertTrue(audio.capturing)
            try await connection.push(["serverContent": ["turnComplete": true]])
            // A retried tool may arrive after that response consumed its input.
            try await connection.push(["toolCall": ["functionCalls": [profile("\(turn)-b")]]])
            XCTAssertEqual(phase, .listening)
            XCTAssertFalse(connection.closed)
        }
        XCTAssertEqual(profiles, 6)
        XCTAssertEqual(connection.acknowledgments.count, 9)
        XCTAssertEqual(audio.captureStarts, 1)
        XCTAssertEqual(connection.input.filter { $0 == .endUtterance }.count, 3)
        live.stop()
        try await run.value
        XCTAssertFalse(audio.capturing)
    }

    func testNextAnswerDuringTrailingSilenceIsNotLostToOldCompletion() async throws {
        let audio = TestLiveAudio(), connection = TestLiveConnection()
        let live = GeminiLiveController(audio: audio, makeConnection: { connection }, now: { audio.time })
        var phase: ConversationController.Phase?
        var interruptions = 0
        live.onPhase = { phase = $0 }
        live.onInterruption = { interruptions += 1 }
        try await live.prepare(capture: true)
        let credentials = try credentials()
        let run = Task { try await live.run(credentials: credentials) }
        await connection.waitForStart()
        try await connection.push(["setupComplete": [:]])
        audio.answer()
        await connection.waitForInputEnds(1)
        try await connection.push(["toolCall": ["functionCalls": [profile("first")]]])
        try await connection.push(audioEvent)
        audio.questionEndedWithSilenceQueued()
        audio.waitForEchoTail()
        audio.answer()
        await connection.waitForInputEnds(2)
        XCTAssertEqual(phase, .processing)
        XCTAssertEqual(interruptions, 1, "Supersede unfinished old output without restarting capture")
        try await connection.push(["serverContent": ["interrupted": true]])
        try await connection.push(["serverContent": ["turnComplete": true]])
        XCTAssertEqual(phase, .processing, "Cancelled completion must not overwrite the newer answer")
        try await connection.push(["toolCall": ["functionCalls": [profile("second")]]])
        XCTAssertEqual(connection.acknowledgments, ["first", "second"])
        XCTAssertFalse(connection.closed)
        XCTAssertEqual(audio.captureStarts, 1)
        live.stop()
        try await run.value
    }

    func testScreenStatesDistinguishConnectingListeningAndSpeaking() {
        XCTAssertEqual(ConversationController.Phase.connecting.screenTitleKey, "voiceConnectingTitle")
        XCTAssertEqual(ConversationController.Phase.listening.screenTitleKey, "voiceListeningTitle")
        XCTAssertEqual(ConversationController.Phase.speaking.microphoneActionKey, "interruptReply")
        XCTAssertEqual(ConversationController.Phase.listening.microphoneActionKey, "pauseConversation")
        XCTAssertEqual(ConversationController.Phase.settling.screenTitleKey, "voiceSettlingTitle")
    }

    func testLoudPlaybackAndDelayedEchoNeverUploadOrInterrupt() async throws {
        let audio = TestLiveAudio(), connection = TestLiveConnection()
        let live = GeminiLiveController(audio: audio, makeConnection: { connection }, now: { audio.time })
        var phase: ConversationController.Phase?
        var interruptions = 0
        live.onPhase = { phase = $0 }
        live.onInterruption = { interruptions += 1 }
        try await live.prepare(capture: true)
        let credentials = try credentials()
        let run = Task { try await live.run(credentials: credentials) }
        await connection.waitForStart()
        try await connection.push(["setupComplete": [:]])
        audio.answer()
        await connection.waitForInputEnds(1)
        try await connection.push(["toolCall": ["functionCalls": [profile("first")]]])
        try await connection.push(audioEvent)
        let count = connection.input.count
        let echo = Data(repeating: 127, count: 3200)
        for _ in 0..<30 { audio.feed(echo, power: -2) }
        XCTAssertEqual(phase, .speaking, "Even loud speech must not interrupt output")
        XCTAssertTrue(audio.isAudible)
        XCTAssertEqual(interruptions, 0)
        audio.questionEndedWithSilenceQueued()
        audio.time += 0.3
        audio.feed(echo, power: -2)
        XCTAssertEqual(phase, .settling)
        XCTAssertEqual(connection.input.count, count)
        try await connection.push(["serverContent": ["turnComplete": true]])
        XCTAssertEqual(phase, .settling, "Remote completion cannot bypass the echo tail")
        audio.waitForEchoTail()
        XCTAssertEqual(phase, .listening)
        // Captured during playback but delivered after the UI has rearmed.
        for _ in 0..<5 { audio.feed(echo, power: -2, capturedAt: 1000.2) }
        audio.answer()
        await connection.waitForInputEnds(2)
        XCTAssertEqual(phase, .processing)
        XCTAssertEqual(audio.captureStarts, 1)
        XCTAssertEqual(interruptions, 0)
        for case .audio(let pcm) in connection.input {
            XCTAssertNil(pcm.range(of: echo.prefix(16)), "Echo must not leak through retained pre-roll")
        }
        live.stop()
        try await run.value
    }

    func testMicTapInterruptsThenRearmsAndStopDuringTailCannotRestart() async throws {
        let audio = TestLiveAudio(), connection = TestLiveConnection()
        let live = GeminiLiveController(audio: audio, makeConnection: { connection }, now: { audio.time })
        var phase: ConversationController.Phase?
        live.onPhase = { phase = $0 }
        try await live.prepare(capture: true)
        let credentials = try credentials()
        let run = Task { try await live.run(credentials: credentials) }
        await connection.waitForStart()
        try await connection.push(["setupComplete": [:]])
        audio.answer()
        await connection.waitForInputEnds(1)
        try await connection.push(["toolCall": ["functionCalls": [profile("first")]]])
        try await connection.push(audioEvent)
        XCTAssertTrue(live.interrupt())
        XCTAssertFalse(audio.isAudible)
        XCTAssertTrue(audio.capturing)
        XCTAssertEqual(phase, .settling)
        // Already in-flight output must not restart playback after the tap.
        try await connection.push(audioEvent)
        XCTAssertFalse(audio.isAudible)
        try await connection.push(["serverContent": ["interrupted": true]])
        try await connection.push(["serverContent": ["turnComplete": true]])
        audio.waitForEchoTail()
        XCTAssertEqual(phase, .listening)
        audio.answer()
        await connection.waitForInputEnds(2)
        try await connection.push(["toolCall": ["functionCalls": [profile("second")]]])
        try await connection.push(audioEvent)
        audio.questionEndedWithSilenceQueued()
        XCTAssertEqual(phase, .settling)
        live.stop()
        audio.waitForEchoTail()
        XCTAssertEqual(phase, .settling, "Stopped controllers must not publish an automatic rearm")
        XCTAssertFalse(audio.capturing)
        XCTAssertTrue(connection.closed)
        XCTAssertEqual(audio.captureStarts, 1)
        try await run.value
    }

    func testRemoteInterruptionAlsoReleasesTheSpeakerHold() async throws {
        let audio = TestLiveAudio(), connection = TestLiveConnection()
        let live = GeminiLiveController(audio: audio, makeConnection: { connection }, now: { audio.time })
        var phase: ConversationController.Phase?
        live.onPhase = { phase = $0 }
        try await live.prepare(capture: true)
        let credentials = try credentials()
        let run = Task { try await live.run(credentials: credentials) }
        await connection.waitForStart()
        try await connection.push(["setupComplete": [:]])
        audio.answer()
        await connection.waitForInputEnds(1)
        try await connection.push(["toolCall": ["functionCalls": [profile("first")]]])
        try await connection.push(audioEvent)
        // Already-sent input can make Google interrupt even though new mic PCM
        // has been blocked locally. This must not leave a permanent input hold.
        try await connection.push(["serverContent": ["interrupted": true]])
        try await connection.push(["serverContent": ["turnComplete": true]])
        XCTAssertEqual(phase, .settling)
        audio.waitForEchoTail()
        XCTAssertEqual(phase, .listening)
        XCTAssertTrue(audio.capturing)
        XCTAssertFalse(connection.closed)
        live.stop()
        try await run.value
    }
}
