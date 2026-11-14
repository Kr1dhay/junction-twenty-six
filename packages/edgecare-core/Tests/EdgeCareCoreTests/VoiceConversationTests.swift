import XCTest
@testable import EdgeCareCore

final class VoiceConversationTests: XCTestCase {
    func testSilenceAndBriefNoiseAreNotSubmitted() {
        var silence = SpeechTurnDetector()
        for tick in 1..<120 {
            XCTAssertEqual(silence.sample(power: tick == 10 ? -15 : -80, elapsed: Double(tick) / 10), .listening)
        }
        XCTAssertFalse(silence.hasSpeech)
        XCTAssertEqual(silence.sample(power: -80, elapsed: 12), .noSpeech)
    }

    func testUtteranceEndsAfterPauseRatherThanRequiringTap() {
        var detector = SpeechTurnDetector()
        for tick in 1...15 {
            XCTAssertEqual(detector.sample(power: -20, elapsed: Double(tick) / 10), .listening)
        }
        XCTAssertTrue(detector.hasSpeech)
        for tick in 16..<30 {
            XCTAssertEqual(detector.sample(power: -90, elapsed: Double(tick) / 10), .listening)
        }
        XCTAssertEqual(detector.sample(power: -90, elapsed: 3), .speechEnded)
    }

    func testShortPauseWithinAnswerDoesNotSplitTurn() {
        var detector = SpeechTurnDetector()
        for tick in 1...40 {
            let power: Float = (11...20).contains(tick) ? -90 : -20
            XCTAssertEqual(detector.sample(power: power, elapsed: Double(tick) / 10), .listening)
        }
        XCTAssertTrue(detector.hasSpeech)
        XCTAssertEqual(detector.sample(power: -90, elapsed: 5.5), .speechEnded)
    }

    func testContinuousSpeechIsBoundedAndBadClockSamplesAreIgnored() {
        var detector = SpeechTurnDetector()
        for tick in 1..<300 {
            XCTAssertEqual(detector.sample(power: -20, elapsed: Double(tick) / 10), .listening)
        }
        XCTAssertEqual(detector.sample(power: -20, elapsed: .nan), .listening)
        XCTAssertEqual(detector.sample(power: -20, elapsed: 1), .listening)
        XCTAssertEqual(detector.sample(power: -20, elapsed: 30), .speechEnded)
    }

    func testAutomaticLoopStopsAfterCompleteReplyOrSpokenStop() {
        for complete in [true, false] {
            var loop = VoiceConversationLoop()
            loop.start()
            loop.receivedResponse(conversationEnded: false, speechAvailable: true)
            XCTAssertTrue(loop.isRunning)
            // conversationEnded covers either complete intake or an early stop request.
            let response = responseJSON(intakeComplete: complete, conversationEnded: true)
            let decoded = try! JSONDecoder().decode(VoiceTurnResponse.self, from: response)
            loop.receivedResponse(conversationEnded: decoded.conversationEnded, speechAvailable: true)
            XCTAssertFalse(loop.isRunning)
            XCTAssertFalse(loop.reachedTurnLimit)
            XCTAssertEqual(decoded.intakeComplete, complete)
            loop.receivedResponse(conversationEnded: false, speechAvailable: true)
            XCTAssertFalse(loop.isRunning, "A delayed callback cannot restart a stopped conversation")
        }
    }

    func testMissingSpeechManualPauseAndTurnLimitNeverAutomaticallyRetry() {
        var loop = VoiceConversationLoop(turnLimit: 3)
        loop.start()
        loop.receivedResponse(conversationEnded: false, speechAvailable: false)
        XCTAssertFalse(loop.isRunning)
        loop.start()
        loop.stop()
        loop.receivedResponse(conversationEnded: false, speechAvailable: true)
        XCTAssertFalse(loop.isRunning)
        loop.start()
        for _ in 0..<3 { loop.receivedResponse(conversationEnded: false, speechAvailable: true) }
        XCTAssertFalse(loop.isRunning)
        XCTAssertTrue(loop.reachedTurnLimit)
        loop.start()
        XCTAssertTrue(loop.isRunning)
        XCTAssertFalse(loop.reachedTurnLimit)
        XCTAssertEqual(loop.turns, 0)
    }

    func testCompletionWireCompatibilityAndEnglishProfile() throws {
        let response = try JSONDecoder().decode(VoiceTurnResponse.self, from: responseJSON(intakeComplete: true, conversationEnded: true))
        XCTAssertTrue(response.intakeComplete)
        XCTAssertTrue(response.conversationEnded)
        XCTAssertEqual(response.profile.durationEnglish, "Two days")
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: responseJSON(intakeComplete: false, conversationEnded: false)) as? [String: Any])
        old.removeValue(forKey: "intake_complete"); old.removeValue(forKey: "conversation_ended")
        let decoded = try JSONDecoder().decode(VoiceTurnResponse.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertFalse(decoded.intakeComplete)
        XCTAssertFalse(decoded.conversationEnded)
        let request = VoiceTurnRequest(consent: true, text: "A cough")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertNil(encoded["intake_complete"], "Completion is a server result, never a client assertion")
    }

    private func responseJSON(intakeComplete: Bool, conversationEnded: Bool) -> Data {
        let profile: [String: Any] = ["concern_english": "Cough", "symptoms_english": ["Cough"], "duration_english": "Two days", "additional_context_english": ""]
        let response: [String: Any] = [
            "transcript": "A cough for two days", "detected_language": "en", "reply": "Thank you.",
            "profile": profile,
            "intake_complete": intakeComplete, "conversation_ended": conversationEnded, "speech_available": false,
        ]
        return try! JSONSerialization.data(withJSONObject: response)
    }
}
