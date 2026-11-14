import XCTest
import EdgeCareCore

/// Opt-in end-to-end check of live transcription against the real provider. Skipped unless the
/// runner supplies a short-lived scribe token minted by the backend and a raw 16 kHz mono PCM16 file:
///   TEST_RUNNER_SCRIBE_TOKEN, TEST_RUNNER_SCRIBE_MODEL, TEST_RUNNER_SCRIBE_URL,
///   TEST_RUNNER_SCRIBE_LANGS ("en,so"), TEST_RUNNER_SCRIBE_AUDIO (path), TEST_RUNNER_SCRIBE_EXPECT (word)
final class ScribeLiveTests: XCTestCase {
    func testStreamedSpeechIsTranscribed() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["SCRIBE_TOKEN"], let model = env["SCRIBE_MODEL"], let url = env["SCRIBE_URL"],
              let langs = env["SCRIBE_LANGS"]?.split(separator: ","), langs.count == 2,
              let path = env["SCRIBE_AUDIO"], let expected = env["SCRIBE_EXPECT"] else {
            throw XCTSkip("Live scribe credentials not supplied")
        }
        let pcm = try Data(contentsOf: URL(fileURLWithPath: path))  // raw 16 kHz mono PCM16
        let client = RealtimeScribeClient()
        let stream = try await client.connect(endpoint: RealtimeEndpoint(token: token, model: model, url: url),
                                              doctorLanguage: String(langs[0]), patientLanguage: String(langs[1]))
        let collector = Task { () -> (started: Bool, committed: [String], failures: [String]) in
            var started = false, committed: [String] = [], failures: [String] = []
            for await event in stream {
                switch event {
                case .started: started = true
                case .committed(let text, _): committed.append(text)
                case .failed(let message): failures.append(message)
                case .closed: return (started, committed, failures)
                case .partial: break
                }
                if !committed.isEmpty { return (started, committed, failures) }
            }
            return (started, committed, failures)
        }
        // Stream like the microphone: 100 ms chunks in real time, then trailing silence for VAD.
        var offset = pcm.startIndex
        while offset < pcm.endIndex {
            let end = min(offset + PCMChunkSize.bytes, pcm.endIndex)
            await client.send(pcm: Data(pcm[offset..<end])); offset = end
            try await Task.sleep(for: .milliseconds(100))
        }
        for _ in 0..<20 { await client.send(pcm: Data(count: PCMChunkSize.bytes)); try await Task.sleep(for: .milliseconds(100)) }
        await client.commit()
        let timeout = Task { try await Task.sleep(for: .seconds(15)); await client.close() }
        let result = await collector.value
        timeout.cancel(); await client.close()
        XCTAssertTrue(result.failures.isEmpty, "Provider errors: \(result.failures)")
        XCTAssertTrue(result.started, "Session never started")
        let text = result.committed.joined(separator: " ").lowercased()
        print("SCRIBE_TRANSCRIPT[\(langs.joined(separator: ","))]: \(text)")
        XCTAssertTrue(text.contains(expected.lowercased()), "Transcript '\(text)' does not contain '\(expected)'")
    }
}

private enum PCMChunkSize { static let bytes = 3200 }
