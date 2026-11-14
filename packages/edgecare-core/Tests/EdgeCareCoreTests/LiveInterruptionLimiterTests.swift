import XCTest
@testable import EdgeCareCore

final class LiveInterruptionLimiterTests: XCTestCase {
    func testRapidRepeatedInterruptionsPauseInsteadOfLooping() {
        var limiter = LiveInterruptionLimiter()
        XCTAssertFalse(limiter.shouldPause(interruptionAt: 100))
        XCTAssertFalse(limiter.shouldPause(interruptionAt: 102))
        XCTAssertFalse(limiter.shouldPause(interruptionAt: 104))
        XCTAssertTrue(limiter.shouldPause(interruptionAt: 106))
    }

    func testOrdinarySpacedCorrectionsDoNotTriggerFeedbackLimit() {
        var limiter = LiveInterruptionLimiter()
        for time in stride(from: 0.0, through: 100, by: 10) {
            XCTAssertFalse(limiter.shouldPause(interruptionAt: time))
        }
    }

    func testInvalidTimesAndFreshSessionDoNotCountAsInterruptions() {
        var limiter = LiveInterruptionLimiter()
        for time in [Double.nan, .infinity, -1] { XCTAssertFalse(limiter.shouldPause(interruptionAt: time)) }
        for time in [1.0, 2, 3] { XCTAssertFalse(limiter.shouldPause(interruptionAt: time)) }
        limiter = LiveInterruptionLimiter()
        XCTAssertFalse(limiter.shouldPause(interruptionAt: 4))
    }
}
