import XCTest
@testable import EdgeCareCore

final class GeminiLiveTests: XCTestCase {
    private func update(duration: String = "Two days", stopped: Bool = false) throws -> GeminiLiveProfileUpdate {
        let value: [String: Any] = ["detected_language": "fi", "stop_requested": stopped,
            "profile": ["concern_english": "Cough", "symptoms_english": ["Cough"],
                        "duration_english": duration, "additional_context_english": ""]]
        return try JSONDecoder().decode(GeminiLiveProfileUpdate.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testCompletionUsesEnglishEssentialsAndEarlyStopDoesNotInventDuration() throws {
        let incomplete = try update(duration: "")
        XCTAssertFalse(incomplete.intakeComplete)
        XCTAssertFalse(incomplete.conversationEnded)
        let complete = try update()
        try complete.validate()
        XCTAssertTrue(complete.intakeComplete)
        XCTAssertTrue(complete.conversationEnded)
        XCTAssertEqual(complete.detectedLanguage, "fi")
        XCTAssertEqual(complete.profile.durationEnglish, "Two days")
        let stopped = try update(duration: "", stopped: true)
        XCTAssertFalse(stopped.intakeComplete)
        XCTAssertTrue(stopped.conversationEnded)
        XCTAssertTrue(try update(duration: "Patient does not know the duration").intakeComplete)
    }

    func testLiveEventRetainsAllAudioPartsAlongsideTranscriptsAndProfile() throws {
        let payload = #"""
        {"serverContent":{"inputTranscription":{"text":"Minulla on yskää."},"outputTranscription":{"text":"Kiitos."},
          "modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AAAAAA=="}},
                                  {"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AQABAA=="}}]},"turnComplete":true},
         "toolCall":{"functionCalls":[{"id":"turn-1","name":"record_intake_profile","args":{"detected_language":"fi",
           "stop_requested":false,"profile":{"concern_english":"Cough","symptoms_english":["Cough"],"duration_english":"Two days","additional_context_english":""}}}]}}
        """#
        let event = try JSONDecoder().decode(GeminiLiveEvent.self, from: Data(payload.utf8))
        XCTAssertEqual(event.serverContent?.modelTurn?.parts?.count, 2)
        XCTAssertEqual(event.serverContent?.inputTranscription?.text, "Minulla on yskää.")
        XCTAssertEqual(event.serverContent?.outputTranscription?.text, "Kiitos.")
        XCTAssertEqual(event.toolCall?.functionCalls.first?.args.profile.durationEnglish, "Two days")
        XCTAssertEqual(event.serverContent?.turnComplete, true)
    }

    func testCredentialsUseOnlyGoogleConstrainedEndpointAndHeaderToken() throws {
        func credential(endpoint: String = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained",
                        seconds: Int = 300, token: String = "auth_tokens/temporary") throws -> GeminiLiveCredentials {
            try JSONDecoder().decode(GeminiLiveCredentials.self, from: JSONSerialization.data(withJSONObject: [
                "token": token, "model": "gemini-3.8-live", "websocket_url": endpoint, "setup_json": "{}", "max_session_seconds": seconds,
            ]))
        }
        let request = try credential().request()
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token auth_tokens/temporary")
        XCTAssertThrowsError(try credential(endpoint: "wss://attacker.example/live").request())
        XCTAssertThrowsError(try credential(seconds: 301).request())
        XCTAssertThrowsError(try credential(token: "bad\r\nheader").request())
        XCTAssertThrowsError(try credential(token: "").request())
    }

    func testMalformedOrUnboundedProfileCannotReplacePreviousProfile() throws {
        XCTAssertThrowsError(try update(duration: String(repeating: "x", count: 501)).validate())
        let malformed = Data(#"{"detected_language":"fi","stop_requested":false,"profile":{"concern_english":"Cough"}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(GeminiLiveProfileUpdate.self, from: malformed))
    }
    func testPCMFormatSilenceDetectionAndReplayContainer() throws {
        XCTAssertNil(PCM16Audio.power(Data([0])))
        XCTAssertLessThan(try XCTUnwrap(PCM16Audio.power(Data(repeating: 0, count: 4800))), -50)
        let loud = Data([0, 64, 0, 192]) // +16384 and -16384 in little endian.
        XCTAssertEqual(try XCTUnwrap(PCM16Audio.power(loud)), -6.02, accuracy: 0.02)
        let wave = try PCM16Audio.wave(loud)
        XCTAssertEqual(String(data: wave.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(wave.count, loud.count + 44)
        XCTAssertEqual(wave.suffix(loud.count), loud)
    }
}
