import XCTest
@testable import EdgeCareCore

final class AdaptiveSpeechInputTests: XCTestCase {
    func testRoomNoiseDoesNotStartSpeechAndFloorAdaptsWithoutCalibration() {
        var detector = AdaptiveSpeechActivity()
        for power: Float in [-34, -32, -30, -33, -29, -34, -31, -32] {
            let sample = detector.sample(power: power, duration: 0.1)
            XCTAssertFalse(sample.speechStarted)
            XCTAssertFalse(sample.passAudio)
        }
        XCTAssertEqual(detector.noiseFloor, -33)
        XCTAssertEqual(detector.threshold, -23)
    }

    func testImmediateSpeechRequiresNoQuietSetupAndRetainsFirstSyllable() throws {
        var input = AdaptiveSpeechInput()
        let first = Data(repeating: 1, count: 3200)
        let second = Data(repeating: 2, count: 3200)
        XCTAssertFalse(try XCTUnwrap(input.process(first, power: -15)).activity.speechStarted)
        let onset = try XCTUnwrap(input.process(second, power: -15))
        XCTAssertTrue(onset.activity.speechStarted)
        XCTAssertEqual(onset.audio, first + second)
    }

    func testBriefClickDoesNotStartUtterance() {
        var detector = AdaptiveSpeechActivity()
        XCTAssertFalse(detector.sample(power: -8, duration: 0.1).speechStarted)
        for _ in 0..<10 {
            XCTAssertFalse(detector.sample(power: -32, duration: 0.1).speechStarted)
        }
    }

    func testPauseEndsAfterSevenHundredMillisecondsDespiteContinuingRoomNoise() {
        var detector = AdaptiveSpeechActivity()
        for _ in 0..<10 { _ = detector.sample(power: -32, duration: 0.1) }
        _ = detector.sample(power: -15, duration: 0.1)
        XCTAssertTrue(detector.sample(power: -15, duration: 0.1).speechStarted)
        for _ in 0..<6 {
            XCTAssertFalse(detector.sample(power: -30, duration: 0.1).speechEnded)
        }
        XCTAssertTrue(detector.sample(power: -30, duration: 0.1).speechEnded)
        XCTAssertFalse(detector.sample(power: -30, duration: 0.1).speechEnded)
        _ = detector.sample(power: -15, duration: 0.1)
        XCTAssertTrue(detector.sample(power: -15, duration: 0.1).speechStarted)
    }

    func testShortPauseAndSofterSyllablesDoNotEndSpeech() {
        var detector = AdaptiveSpeechActivity()
        _ = detector.sample(power: -32, duration: 0.1)
        _ = detector.sample(power: -15, duration: 0.2)
        for _ in 0..<5 { XCTAssertFalse(detector.sample(power: -32, duration: 0.1).speechEnded) }
        XCTAssertTrue(detector.sample(power: -24, duration: 0.1).speechDetected)
        for _ in 0..<6 { XCTAssertFalse(detector.sample(power: -32, duration: 0.1).speechEnded) }
        XCTAssertTrue(detector.sample(power: -32, duration: 0.1).speechEnded)
    }

    func testBackgroundBecomesZeroPCMAndPreRollIsBounded() throws {
        var input = AdaptiveSpeechInput()
        let noise = Data(repeating: 3, count: 3200)
        for _ in 0..<30 {
            XCTAssertEqual(try XCTUnwrap(input.process(noise, power: -32)).audio, Data(count: 3200))
        }
        let speech = Data(repeating: 4, count: 3200)
        _ = input.process(speech, power: -15)
        let onset = try XCTUnwrap(input.process(speech, power: -15))
        XCTAssertTrue(onset.activity.speechStarted)
        XCTAssertEqual(onset.audio.count, 12800)
        XCTAssertEqual(onset.audio.suffix(6400), speech + speech)
        _ = input.process(noise, power: -32)
        XCTAssertEqual(try XCTUnwrap(input.process(noise, power: -32)).audio, Data(count: 3200))
    }

    func testInvalidSamplesCannotStartOrEndSpeech() {
        var detector = AdaptiveSpeechActivity()
        for (power, duration): (Float, Double) in [(.nan, 0.1), (.infinity, 0.1), (-10, 0), (-10, -1), (-10, .nan), (-10, 1)] {
            XCTAssertFalse(detector.sample(power: power, duration: duration).speechStarted)
        }
        var input = AdaptiveSpeechInput()
        XCTAssertNil(input.process(Data(), power: -15))
        XCTAssertNil(input.process(Data(count: 3), power: -15))
        XCTAssertNil(input.process(Data(count: 8002), power: -15))
        XCTAssertNil(input.process(Data(count: 3200), power: .nan))
    }

    func testInterruptionBlocksStaleOutputUntilServerBoundaryThenAllowsNextReply() {
        var gate = LiveInterruptionGate()
        XCTAssertTrue(gate.acceptsOutput)
        XCTAssertTrue(gate.interrupt())
        XCTAssertFalse(gate.acceptsOutput)
        XCTAssertFalse(gate.interrupt())
        gate.acknowledge()
        XCTAssertTrue(gate.acceptsOutput)
        XCTAssertTrue(gate.interrupt())
    }

    func testInterruptingBufferedClosingAfterRemoteTurnFinishedDoesNotWaitForServer() {
        var gate = LiveInterruptionGate()
        XCTAssertTrue(gate.interrupt(awaitingServer: false))
        XCTAssertFalse(gate.awaitingAcknowledgment)
        XCTAssertTrue(gate.acceptsOutput)
    }

    func testLateTurnCompletionReleasesGateButDiscardsBoundaryPayload() {
        var gate = LiveInterruptionGate()
        _ = gate.interrupt()
        XCTAssertTrue(gate.discardOutput(interrupted: false, turnComplete: false))
        XCTAssertTrue(gate.discardOutput(interrupted: false, turnComplete: true))
        XCTAssertFalse(gate.discardOutput(interrupted: false, turnComplete: false))
    }

    func testRemoteInterruptionDiscardsAudioAndToolsInSameMessage() {
        var gate = LiveInterruptionGate()
        _ = gate.interrupt()
        XCTAssertTrue(gate.discardOutput(interrupted: true, turnComplete: true))
        XCTAssertTrue(gate.acceptsOutput)
        XCTAssertFalse(gate.discardOutput(interrupted: false, turnComplete: false))
        XCTAssertTrue(gate.discardOutput(interrupted: true, turnComplete: false))
    }

    func testSeparateCancelledTurnCompletionAfterAcknowledgementIsNotANewResponse() {
        var gate = LiveInterruptionGate()
        _ = gate.interrupt()
        XCTAssertTrue(gate.discardOutput(interrupted: true, turnComplete: false))
        XCTAssertFalse(gate.discardOutput(interrupted: false, turnComplete: false))
        XCTAssertTrue(gate.discardOutput(interrupted: false, turnComplete: true))
        XCTAssertFalse(gate.discardOutput(interrupted: false, turnComplete: false, hasNewOutput: true))
        XCTAssertFalse(gate.discardOutput(interrupted: false, turnComplete: true))
    }

    func testReplacementOutputCanStartWithoutAnExtraCancelledCompletion() {
        var gate = LiveInterruptionGate()
        _ = gate.interrupt()
        _ = gate.discardOutput(interrupted: true, turnComplete: false)
        XCTAssertFalse(gate.discardOutput(interrupted: false, turnComplete: false, hasNewOutput: true))
        XCTAssertFalse(gate.discardOutput(interrupted: false, turnComplete: true))
    }

    func testPlaybackRequiresStrongerSustainedSpeechNotModerateCrowdBursts() {
        var detector = AdaptiveSpeechActivity()
        for _ in 0..<10 { _ = detector.sample(power: -32, duration: 0.1) }
        // Above the normal onset threshold, but not a convincing interruption.
        for _ in 0..<10 {
            XCTAssertFalse(detector.sample(power: -20, duration: 0.1, duringPlayback: true).speechStarted)
        }
        XCTAssertFalse(detector.sample(power: -12, duration: 0.1, duringPlayback: true).speechStarted)
        XCTAssertFalse(detector.sample(power: -12, duration: 0.1, duringPlayback: true).speechStarted)
        XCTAssertTrue(detector.sample(power: -12, duration: 0.1, duringPlayback: true).speechStarted)
    }

    func testNormalVolumeInterruptionSurvivesSofterSyllablesDuringOnset() {
        var detector = AdaptiveSpeechActivity()
        for _ in 0..<20 { _ = detector.sample(power: -32, duration: 0.1) }
        // Ordinary speech varies in volume; the old 16 dB/every-frame gate
        // rejected this entire interruption, although normal listening heard it.
        XCTAssertFalse(detector.sample(power: -18, duration: 0.1, duringPlayback: true).speechStarted)
        XCTAssertFalse(detector.sample(power: -21, duration: 0.1, duringPlayback: true).speechStarted)
        XCTAssertTrue(detector.sample(power: -20, duration: 0.1, duringPlayback: true).speechStarted)
    }

    func testPlaybackOnsetStillRejectsIsolatedLoudSpikesAndResetsAfterQuiet() {
        var detector = AdaptiveSpeechActivity()
        for _ in 0..<20 { _ = detector.sample(power: -32, duration: 0.1) }
        for _ in 0..<5 {
            XCTAssertFalse(detector.sample(power: -12, duration: 0.1, duringPlayback: true).speechStarted)
            XCTAssertFalse(detector.sample(power: -32, duration: 0.1, duringPlayback: true).speechStarted)
        }
        XCTAssertFalse(detector.sample(power: -18, duration: 0.1, duringPlayback: true).speechStarted)
        XCTAssertFalse(detector.sample(power: -21, duration: 0.1, duringPlayback: true).speechStarted)
        XCTAssertTrue(detector.sample(power: -20, duration: 0.1, duringPlayback: true).speechStarted)
    }
}
