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
    /// Hittability alone is insufficient: XCTest may automatically scroll before
    /// tapping. Check the entire frame before any scrolling or interaction.
    private func assertFits(_ element: XCUIElement, in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        let viewport = app.windows.firstMatch.frame
        let frame = element.frame
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, app.navigationBars.firstMatch.frame.maxY - 1, element.label, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, viewport.maxY - 20, element.label, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, viewport.minX, element.label, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, viewport.maxX, element.label, file: file, line: line)
    }

    func testLandscapeFormAndVoiceFitWithoutScrolling() {
        let app = launch()
        assertFits(app.buttons["Create a new referral"], in: app)
        assertFits(app.buttons["Book an appointment"], in: app)
        app.buttons["Create a new referral"].tap()
        for label in ["A new or changing skin concern", "A new lump or swelling", "Unexplained bleeding",
                      "A persistent cough", "Understanding a screening letter", "Another health concern"] {
            assertFits(app.switches[label], in: app)
            XCTAssertGreaterThanOrEqual(app.switches[label].frame.height, 44)
        }
        assertFits(app.textFields["Optional notes in your language"], in: app)
        assertFits(app.buttons["Continue"], in: app)
        assertFits(app.buttons["Finish and clear session"], in: app)
        capture("15-landscape-form-fit")
        app.segmentedControls.buttons["Voice conversation"].tap()
        assertFits(app.buttons["Start conversation"], in: app)
        assertFits(app.buttons["Use the offline form"], in: app)
        assertFits(app.buttons["Finish and clear session"], in: app)
        XCTAssertGreaterThanOrEqual(app.buttons["Start conversation"].frame.height, 200)
        XCTAssertFalse(app.buttons["Start conversation"].isEnabled)
        capture("16-landscape-voice-fit")
    }

    func testLandscapeReferralPagesFitWithoutScrolling() {
        let app = launch()
        app.buttons["Create a new referral"].tap()
        app.switches["Another health concern"].tap()
        app.buttons["Continue"].tap()
        for _ in 0..<12 {
            if app.staticTexts["Add context, if you want"].exists { break }
            assertFits(app.buttons["No"], in: app)
            assertFits(app.buttons["Finish and clear session"], in: app)
            app.buttons["No"].tap()
        }
        assertFits(app.buttons["Continue"], in: app)
        assertFits(app.buttons["Finish and clear session"], in: app)
        capture("17-landscape-context-fit")
        app.buttons["Continue"].tap()
        assertFits(app.buttons["Create a private referral"], in: app)
        assertFits(app.buttons["Finish and clear session"], in: app)
        capture("18-landscape-guidance-fit")
        app.buttons["Create a private referral"].tap()
        assertFits(app.descendants(matching: .any).matching(identifier: "signatureCanvas").firstMatch, in: app)
        assertFits(app.staticTexts["Choose a 4-digit code"], in: app)
        assertFits(app.staticTexts["Enter the code again"], in: app)
        assertFits(text("There is no code reset. If you forget your code, you lose access to this referral. No name, phone or account can recover it.", in: app), in: app)
        assertFits(app.switches["I understand and will remember my code"], in: app)
        assertFits(app.buttons["Create a private referral"], in: app)
        assertFits(app.buttons["Finish and clear session"], in: app)
        capture("19-landscape-sealing-fit")
        // Never submit a referral or use sample credentials.
    }

    func testLandscapeVerificationPagesFitWithoutScrolling() {
        let app = launch()
        app.buttons["Book an appointment"].tap()
        assertFits(app.staticTexts["Enter your 4-digit code"], in: app)
        assertFits(app.descendants(matching: .any).matching(identifier: "signatureCanvas").firstMatch, in: app)
        assertFits(app.buttons["Verify and load my referral"], in: app)
        assertFits(app.buttons["Finish and clear session"], in: app)
        capture("20-landscape-booking-fit")
        app.buttons["Cancel"].tap()
        app.buttons["Update an existing referral"].tap()
        assertFits(app.staticTexts["Enter your 4-digit code"], in: app)
        assertFits(app.descendants(matching: .any).matching(identifier: "signatureCanvas").firstMatch, in: app)
        assertFits(app.buttons["Verify and load my referral"], in: app)
        assertFits(app.buttons["Cancel"], in: app)
        capture("21-landscape-update-fit")
    }

    func testLandscapeFormFitsInEveryLanguage() {
        for (language, heading) in [("Suomi", "Mikä huolestuttaa sinua?"), ("Soomaali", "Maxaa ku welwelinaya?"),
                                    ("العربية", "ما الذي يقلقك؟"), ("Русский", "Что вас беспокоит?")] {
            let app = launch()
            app.buttons[language].tap()
            app.buttons["intakePrimaryAction"].tap()
            XCTAssertTrue(app.staticTexts[heading].waitForExistence(timeout: 5))
            XCTAssertEqual(app.switches.count, 6)
            for symptom in app.switches.allElementsBoundByIndex { assertFits(symptom, in: app) }
            assertFits(app.buttons["intakePrimaryAction"], in: app)
            assertFits(app.buttons["intakeEndSession"], in: app)
            capture("23-landscape-form-" + language)
            app.terminate()
        }
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
            XCTAssertLessThanOrEqual(app.buttons["voicePause"].frame.maxY,
                                     app.windows.firstMatch.frame.maxY - 20,
                                     "Full-screen voice controls must fit without scrolling: " + phase)
            XCTAssertFalse(app.segmentedControls.buttons["Voice conversation"].isHittable)
            if phase == "listening" || phase == "speaking" {
                XCTAssertGreaterThanOrEqual(app.buttons["voiceMicrophone"].frame.height, 240)
                XCTAssertGreaterThanOrEqual(app.buttons["voiceMicrophone"].frame.width, 240)
                XCTAssertFalse(app.buttons["voiceMicrophone"].label.isEmpty)
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

    func testFormAtAccessibilityTextSizeKeepsSingleColumnAndScrolling() {
        let app = launch(largeText: true)
        tap("Create a new referral", in: app)
        let first = app.switches["A new or changing skin concern"]
        let second = app.switches["A new lump or swelling"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.frame.minX, second.frame.minX, accuracy: 1)
        XCTAssertGreaterThan(second.frame.minY, first.frame.minY)
        tap("Another health concern", in: app, toggle: true)
        capture("22-accessibility-form-scroll")
        tap("Continue", in: app)
        XCTAssertTrue(app.buttons["No"].waitForExistence(timeout: 5))
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
