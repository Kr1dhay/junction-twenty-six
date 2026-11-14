import XCTest
@testable import EdgeCareCore

final class LiveConversationProgressTests: XCTestCase {
    func testSilenceAfterQuestionDoesNotKeepPlaybackAudible() {
        var playback = LivePlaybackProgress()
        let question = playback.enqueue(frames: 24000, audible: true)
        let silence = playback.enqueue(frames: 48000, audible: false)
        playback.played(question)
        XCTAssertFalse(playback.isAudible)
        XCTAssertEqual(playback.queuedFrames, 48000)
        playback.played(silence)
        XCTAssertEqual(playback.queuedFrames, 0)
    }

    func testOldAndDuplicateCompletionsCannotDrainNewReply() {
        var playback = LivePlaybackProgress()
        let old = playback.enqueue(frames: 24000, audible: true)
        playback.reset()
        let current = playback.enqueue(frames: 48000, audible: true)
        XCTAssertFalse(playback.played(old))
        XCTAssertEqual(playback.audibleFrames, 48000)
        XCTAssertTrue(playback.played(current))
        let next = playback.enqueue(frames: 12000, audible: true)
        XCTAssertFalse(playback.played(current))
        XCTAssertEqual(playback.queuedFrames, 12000)
        playback.played(next)
    }

    func testNewPatientInputSurvivesOldResponseCompletion() {
        var progress = LiveInputProgress()
        progress.heardInput()
        progress.beganResponse()
        progress.heardInput()
        XCTAssertTrue(progress.hasNewerInput)
        XCTAssertFalse(progress.endedResponse())
        progress.beganResponse()
        XCTAssertTrue(progress.endedResponse())
    }

    func testSeveralRepliesAndRepeatedProfileUpdatesConsumeOnlyTheirInput() {
        var progress = LiveInputProgress()
        for _ in 0..<5 {
            progress.heardInput()
            progress.beganResponse()
            progress.beganResponse() // More than one tool/audio event in one response.
            XCTAssertTrue(progress.endedResponse())
        }
        progress.heardInput()
        progress.beganResponse()
        progress.interrupted()
        XCTAssertFalse(progress.endedResponse())
    }
}
