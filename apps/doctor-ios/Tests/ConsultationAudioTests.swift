import XCTest
@testable import EdgeCareUI

/// Runs the real consultation microphone pipeline inside the doctor app on a simulator.
/// Regression: the tap block used to inherit @MainActor isolation and trapped on the audio thread
/// (EXC_BREAKPOINT in swift_task_checkIsolatedSwift) as soon as live translation started.
@MainActor final class ConsultationAudioTests: XCTestCase {
    func testMicrophoneTapDeliversAudioOffTheMainThreadWithoutTrapping() async throws {
        let engine = ConsultationAudioEngine()
        let delivered = expectation(description: "audio chunks delivered from the realtime thread")
        delivered.assertForOverFulfill = false
        let started = await engine.start { chunk in
            XCTAssertEqual(chunk.count, PCMChunker.chunkBytes)
            delivered.fulfill()
        }
        try XCTSkipUnless(started, "Microphone unavailable or permission denied on this simulator")
        await fulfillment(of: [delivered], timeout: 10)
        // Keep the tap running a little longer: the original crash happened on the first callbacks.
        try await Task.sleep(for: .seconds(2))
        engine.stop()
    }
}
