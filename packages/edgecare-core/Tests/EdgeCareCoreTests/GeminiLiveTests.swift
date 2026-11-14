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

    func testHybridPauseUsesGeminiAudioStreamEndNotManualActivityOrHTTPRecording() throws {
        let pcm = Data([0, 64, 0, 192])
        let audio = try GeminiLiveInput.audio(pcm).wireObject()["realtimeInput"] as? [String: Any]
        XCTAssertEqual((audio?["audio"] as? [String: Any])?["mimeType"] as? String, "audio/pcm;rate=16000")
        XCTAssertEqual((audio?["audio"] as? [String: Any])?["data"] as? String, pcm.base64EncodedString())
        let end = try GeminiLiveInput.endUtterance.wireObject()["realtimeInput"] as? [String: Any]
        XCTAssertEqual(end?["audioStreamEnd"] as? Bool, true)
        XCTAssertNil(end?["activityEnd"], "Manual activity markers require a different constrained server config")
        XCTAssertThrowsError(try GeminiLiveInput.audio(Data([1])).wireObject())
    }

    func testMicrophoneFinalizesOnceAfterPauseAndResumesOnNextUtteranceWithoutReconnecting() throws {
        var input = GeminiLiveMicrophoneInput()
        let noise = Data(repeating: 1, count: 3200), speech = Data(repeating: 2, count: 3200)
        for _ in 0..<10 {
            XCTAssertTrue(try XCTUnwrap(input.process(noise, power: -32)).messages.isEmpty)
        }
        XCTAssertTrue(try XCTUnwrap(input.process(speech, power: -15)).messages.isEmpty)
        let onset = try XCTUnwrap(input.process(speech, power: -15))
        guard case .audio(let buffered) = try XCTUnwrap(onset.messages.first) else { return XCTFail("Missing Gemini PCM") }
        XCTAssertEqual(buffered.suffix(6400), speech + speech)
        for _ in 0..<6 {
            XCTAssertFalse(try XCTUnwrap(input.process(noise, power: -32)).messages.contains(.endUtterance))
        }
        let end = try XCTUnwrap(input.process(noise, power: -32))
        XCTAssertEqual(end.messages, [.audio(Data(count: 3200)), .endUtterance])
        for _ in 0..<20 {
            XCTAssertTrue(try XCTUnwrap(input.process(noise, power: -32)).messages.isEmpty)
        }
        _ = input.process(speech, power: -15)
        XCTAssertTrue(try XCTUnwrap(input.process(speech, power: -15)).activity.speechStarted)
    }

    func testToolCancellationIsDecodedWithoutDiscardingOtherFieldsInGeminiMessage() throws {
        let payload = Data(#"{"toolCallCancellation":{"ids":["cancelled-1"]},"serverContent":{"interrupted":true,"inputTranscription":{"text":"Synthetic correction"}}}"#.utf8)
        let event = try JSONDecoder().decode(GeminiLiveEvent.self, from: payload)
        XCTAssertEqual(event.toolCallCancellation?.ids, ["cancelled-1"])
        XCTAssertEqual(event.serverContent?.interrupted, true)
        XCTAssertEqual(event.serverContent?.inputTranscription?.text, "Synthetic correction")
    }

    func testNormalVolumeBargeInPassesOnsetPCMToGeminiAndFinalizesCorrection() throws {
        var input = GeminiLiveMicrophoneInput()
        let noise = Data(repeating: 1, count: 3200)
        for _ in 0..<20 { _ = input.process(noise, power: -32) }
        let first = Data(repeating: 2, count: 3200)
        let second = Data(repeating: 3, count: 3200)
        let third = Data(repeating: 4, count: 3200)
        XCTAssertTrue(try XCTUnwrap(input.process(first, power: -18, duringPlayback: true)).messages.isEmpty)
        XCTAssertTrue(try XCTUnwrap(input.process(second, power: -21, duringPlayback: true)).messages.isEmpty)
        let interruption = try XCTUnwrap(input.process(third, power: -20, duringPlayback: true))
        XCTAssertTrue(interruption.activity.speechStarted, "Must stop local playback in this same capture callback")
        guard case .audio(let pcm) = try XCTUnwrap(interruption.messages.first) else { return XCTFail("Missing interruption PCM") }
        XCTAssertEqual(pcm.suffix(9600), first + second + third, "Do not lose the beginning of the correction")
        // Local playback has now stopped, but the same capture stream continues.
        XCTAssertFalse(try XCTUnwrap(input.process(third, power: -21)).activity.speechStarted)
        var messages: [GeminiLiveInput] = []
        for _ in 0..<7 { messages += try XCTUnwrap(input.process(noise, power: -32)).messages }
        XCTAssertEqual(messages.filter { $0 == .endUtterance }.count, 1)
        XCTAssertEqual(messages.last, .endUtterance)
    }
}
