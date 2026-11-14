import XCTest

/// Repeatable visual review without starting cloud voice, granting consent,
/// enrolling a patient, or clearing installed app data.
@MainActor final class DesignReviewTests: XCTestCase {
    private func launch(largeText: Bool = false, portrait: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = portrait ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["EDGECARE_MODE"] = "connected"
        app.launchEnvironment["EDGECARE_BASE_URL"] = "https://edgecare-lissankoiralas-projects.vercel.app"
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["Create a new referral"].waitForExistence(timeout: 15))
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testWelcomeFormAndVoice() {
        let app = launch()
        capture("01-welcome")
        app.buttons["Create a new referral"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Voice conversation"].waitForExistence(timeout: 5))
        capture("02-structured-intake")
        app.segmentedControls.buttons["Voice conversation"].tap()
        XCTAssertFalse(app.staticTexts["Connecting to voice service…"].exists)
        capture("03-voice-ready")
        // Consent stays off. This review never captures/transmits microphone audio.
        XCTAssertFalse(app.buttons["Start conversation"].isEnabled)
    }

    func testWelcomeAtAccessibilityTextSize() {
        let app = launch(largeText: true)
        capture("04-accessibility-welcome")
        for _ in 0..<8 {
            if app.buttons["English"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["English"].isHittable)
        XCTAssertGreaterThan(app.buttons["English"].frame.width, app.buttons["English"].frame.height * 2,
                             "Accessibility language choices must be wide rows, not narrow vertical pills")
        capture("04a-accessibility-languages")
        for _ in 0..<8 {
            if app.buttons["Create a new referral"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["Create a new referral"].isHittable)
        capture("04b-accessibility-actions")
    }

    func testArabicWelcome() {
        let app = launch()
        app.buttons["العربية"].tap()
        XCTAssertTrue(app.buttons["إنشاء إحالة جديدة"].waitForExistence(timeout: 5))
        capture("05-arabic-welcome")
    }

    func testPortraitWelcome() {
        _ = launch(portrait: true)
        capture("06-portrait-welcome")
    }
}
