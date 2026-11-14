import XCTest
@testable import EdgeCareCore

final class LiveSpeakerInputGateTests: XCTestCase {
    func testPlaybackAndEchoTailBlockInputBeforeOrdinaryListeningResumes() {
        var gate = LiveSpeakerInputGate()
        XCTAssertTrue(gate.allowsInput(capturedAt: 10, duration: 0.1))
        gate.beganPlayback()
        XCTAssertFalse(gate.allowsInput(capturedAt: 11, duration: 0.1))
        gate.endedPlayback(at: 12)
        XCTAssertFalse(gate.rearm(at: 12.49))
        XCTAssertFalse(gate.allowsInput(capturedAt: 12.49, duration: 0.1))
        XCTAssertTrue(gate.rearm(at: 12.5))
        XCTAssertFalse(gate.allowsInput(capturedAt: 12.55, duration: 0.1), "Reject buffers straddling the cutoff")
        XCTAssertTrue(gate.allowsInput(capturedAt: 13, duration: 0.1))
        XCTAssertFalse(gate.allowsInput(capturedAt: 12.2, duration: 0.1), "Reject delayed old echo")
    }

    func testNewOutputCancelsRearmAndRepeatedDrainDoesNotExtendTail() {
        var gate = LiveSpeakerInputGate()
        gate.beganPlayback()
        gate.endedPlayback(at: 10)
        gate.beganPlayback()
        XCTAssertFalse(gate.rearm(at: 11))
        gate.endedPlayback(at: 12)
        gate.endedPlayback(at: 12.4)
        XCTAssertTrue(gate.rearm(at: 12.5))
        XCTAssertFalse(gate.rearm(at: 13), "Rearm only once")
    }

    func testSuspensionClearsOnsetAndPreRollButRetainsAmbientEstimate() throws {
        var microphone = GeminiLiveMicrophoneInput()
        let noise = Data(repeating: 0, count: 3200)
        let echo = Data(repeating: 127, count: 3200)
        let answer = Data(repeating: 2, count: 3200)
        for _ in 0..<20 { _ = microphone.process(noise, power: -32) }
        _ = microphone.process(echo, power: -15) // Candidate, not yet confirmed.
        XCTAssertTrue(microphone.suspendForPlayback().isEmpty)
        XCTAssertFalse(try XCTUnwrap(microphone.process(answer, power: -15)).activity.speechStarted)
        let onset = try XCTUnwrap(microphone.process(answer, power: -15))
        XCTAssertTrue(onset.activity.speechStarted)
        guard case .audio(let pcm) = try XCTUnwrap(onset.messages.first) else { return XCTFail("Missing onset audio") }
        XCTAssertNil(pcm.range(of: echo.prefix(16)))
        XCTAssertEqual(microphone.suspendForPlayback(), [.endUtterance])
        XCTAssertTrue(microphone.suspendForPlayback().isEmpty)
        var detector = AdaptiveSpeechActivity()
        for _ in 0..<20 { _ = detector.sample(power: -32, duration: 0.1) }
        let floor = detector.noiseFloor
        detector.resetSpeech()
        XCTAssertEqual(detector.noiseFloor, floor)
    }
}
