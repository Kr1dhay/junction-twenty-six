import XCTest

/// Repeatable visual review without starting cloud voice, granting consent,
/// enrolling a patient, or clearing installed app data.
@MainActor final class DesignReviewTests: XCTestCase {
    private func launch(largeText: Bool = false, portrait: Bool = false, voicePhase: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = portrait ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["EDGECARE_MODE"] = "connected"
        app.launchEnvironment["EDGECARE_BASE_URL"] = "https://edgecare-lissankoiralas-projects.vercel.app"
        if let voicePhase { app.launchEnvironment["EDGECARE_VOICE_REVIEW_PHASE"] = voicePhase }
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

    private func tap(_ label: String, in app: XCUIApplication, toggle: Bool = false) {
        let button = toggle ? app.switches[label] : app.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 5), label)
        for _ in 0..<8 {
            if button.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(button.isHittable, label)
        button.tap()
    }
    private func text(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func testGuidanceIsDeclutteredAndSourcesRemainAvailable() {
        let app = launch()
        XCTAssertFalse(app.staticTexts["Shared-backend demo"].exists)
        XCTAssertFalse(app.buttons["Demo controls"].exists)
        XCTAssertFalse(app.staticTexts["This session clears after 3 minutes without activity."].exists)
        tap("Create a new referral", in: app)
        tap("Another health concern", in: app, toggle: true)
        tap("Continue", in: app)
        for _ in 0..<12 {
            if app.staticTexts["Add context, if you want"].exists { break }
            tap("No", in: app)
        }
        XCTAssertTrue(app.staticTexts["Add context, if you want"].exists)
        XCTAssertFalse(text("Text read on device. Check and edit it; OCR can make mistakes. Remove names and contact details before continuing.", in: app).exists)
        capture("14-optional-context-clean")
        tap("Continue", in: app)
        XCTAssertTrue(app.staticTexts["Your next step"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Demo triage for clinician review. A score is a routing aid, not a cancer probability."].exists)
        XCTAssertFalse(app.staticTexts["Speech recognition requests on-device processing only. You can always type instead."].exists)
        XCTAssertFalse(app.links["NHS · cancer information"].exists)
        XCTAssertTrue(app.buttons["Create a private referral"].isHittable)
        capture("10-guidance-clean")
        tap("Sources", in: app)
        XCTAssertTrue(app.links["NHS · cancer information"].exists)
        tap("Sources", in: app)
        tap("Create a private referral", in: app)
        XCTAssertTrue(text("There is no code reset. If you forget your code, you lose access to this referral. No name, phone or account can recover it.", in: app).exists)
        XCTAssertFalse(app.buttons["Synthetic demo · sample signature and code 1234"].exists)
        capture("11-private-referral-clean")
    }

    func testEmergencyAdviceRemainsVisible() {
        let app = launch()
        tap("Create a new referral", in: app)
        tap("Another health concern", in: app, toggle: true)
        tap("Continue", in: app)
        tap("Yes", in: app)
        XCTAssertTrue(app.staticTexts["Emergency help is recommended"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.links["Call 112"].exists)
        XCTAssertTrue(app.staticTexts["Call 112 now for possible emergency symptoms. Do not wait for a referral."].exists)
        capture("12-emergency-advice")
        // Do not follow the telephone link or submit a referral.
    }

    func testWelcomeFormAndVoice() {
        let app = launch()
        capture("01-welcome")
        tap("Privacy and care information", in: app)
        XCTAssertTrue(text("This demo provides guidance for clinician review, not a diagnosis. The form stays on this device until you seal a referral. Optional online voice sends data to external providers only with your consent.", in: app).exists)
        tap("Privacy and care information", in: app)
        app.buttons["Create a new referral"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Voice conversation"].waitForExistence(timeout: 5))
        capture("02-structured-intake")
        app.segmentedControls.buttons["Voice conversation"].tap()
        XCTAssertFalse(app.staticTexts["Connecting to voice service…"].exists)
        capture("03-voice-ready")
        // Consent stays off. This review never captures/transmits microphone audio.
        XCTAssertFalse(app.buttons["Start conversation"].isEnabled)
        XCTAssertGreaterThanOrEqual(app.buttons["Start conversation"].frame.height, 200)
    }

    func testBookingHasOneConciseBoundaryNotice() {
        let app = launch()
        tap("Book an appointment", in: app)
        XCTAssertTrue(app.staticTexts["This does not reserve a real clinic appointment."].waitForExistence(timeout: 5))
        XCTAssertFalse(text("Shared demo schedule only. This does not book a real clinic appointment. For emergency symptoms, follow the emergency advice immediately.", in: app).exists)
        capture("13-booking-clean")
    }

    func testFullScreenVoiceStatesWithoutCapturingAudio() {
        for (phase, title) in [("connecting", "Connecting to Edi…"), ("listening", "Speak now"),
                               ("processing", "One moment…"), ("speaking", "Edi is speaking"),
                               ("settling", "Getting ready to listen…")] {
            let app = launch(voicePhase: phase)
            app.buttons["Create a new referral"].tap()
            app.segmentedControls.buttons["Voice conversation"].tap()
            XCTAssertTrue(app.staticTexts["voiceStageTitle"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["voiceStageTitle"].label, title)
            capture("07-fullscreen-" + phase)
            XCTAssertTrue(app.buttons["voiceBack"].isHittable)
            XCTAssertFalse(app.segmentedControls.buttons["Voice conversation"].isHittable)
            if phase == "listening" || phase == "speaking" {
                XCTAssertGreaterThanOrEqual(app.buttons["voiceMicrophone"].frame.height, 200)
            }
            if phase == "speaking" {
                XCTAssertTrue(text("Tap the microphone to interrupt. Your microphone is paused while Edi speaks and resumes automatically afterward.", in: app).exists)
            }
            if phase == "settling" {
                XCTAssertFalse(app.buttons["voiceMicrophone"].exists)
            }
            app.buttons["voiceBack"].tap()
            XCTAssertTrue(app.buttons["Start conversation"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Start conversation"].isEnabled, "Review must not grant microphone consent")
            app.terminate()
        }
    }

    func testReadAloudStartsPlayback() {
        let app = launch()
        app.buttons["Create a new referral"].tap()
        let read = app.buttons["readAloud"]
        XCTAssertTrue(read.waitForExistence(timeout: 5))
        read.tap()
        XCTAssertTrue(app.staticTexts["Reading aloud…"].waitForExistence(timeout: 8),
                      "Require synthesis didStart, not merely a queued utterance")
        capture("08-read-aloud")
        read.tap()
        XCTAssertTrue(app.buttons["Read aloud"].waitForExistence(timeout: 5))
    }

    func testFullScreenVoiceAtAccessibilitySizeInPortrait() {
        let app = launch(largeText: true, portrait: true, voicePhase: "listening")
        app.buttons["Create a new referral"].tap()
        app.segmentedControls.buttons["Voice conversation"].tap()
        XCTAssertTrue(app.staticTexts["voiceStageTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["voiceBack"].isHittable)
        capture("09-fullscreen-accessibility-portrait")
        app.buttons["voiceBack"].tap()
        XCTAssertTrue(app.buttons["Start conversation"].waitForExistence(timeout: 5))
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
