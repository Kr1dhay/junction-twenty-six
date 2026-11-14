import XCTest
import EdgeCareCore
@testable import EdgeCareUI

@MainActor final class VoiceResearchUITests: XCTestCase {
    func testOfferForRelevantIntakeEvenWithEmergencyAdvice() {
        let model = IntakeViewModel(source: .kiosk)
        model.clinicalProfile = ClinicalProfile(concernEnglish: "Hoarseness for a month")
        XCTAssertTrue(model.shouldOfferVoiceResearch)
        model.beginSafetyQuestions()
        model.answerSafetyQuestion(.yes)
        XCTAssertTrue(model.requiresEmergencyAdvice)
        XCTAssertTrue(model.shouldOfferVoiceResearch)
        model.reset()
        XCTAssertFalse(model.shouldOfferVoiceResearch)
    }
    func testOfferDependsOnConversationProfileNotTypedNotes() {
        let model = IntakeViewModel(source: .kiosk)
        model.concern = "I have a hoarse voice"
        XCTAssertFalse(model.shouldOfferVoiceResearch, "Typed form notes alone must not trigger the voice task")
        model.clinicalProfile = ClinicalProfile(concernEnglish: "Hoarse voice", symptomsEnglish: ["Hoarse voice"])
        XCTAssertTrue(model.shouldOfferVoiceResearch, "The agent conversation profile drives the offer")
    }
    func testResetClearsResultConsentDecisionAndReportCopyNeverReassures() {
        let model = IntakeViewModel(source: .kiosk)
        model.voiceResearchDecision = "completed"
        model.voiceResearch = VoiceResearchAssessment(outcome: .notFlagged, assessedAt: "2026-11-14T12:00:00Z",
            modelID: "synthetic-test-only", modelVersion: "test", sampleDurationSeconds: 6)
        model.reset()
        XCTAssertNil(model.voiceResearch); XCTAssertNil(model.voiceResearchDecision)
        XCTAssertTrue(Copy.text("voiceResearchNotFlagged", "en").contains("does not rule out cancer"))
        XCTAssertTrue(Copy.text("voiceResearchFlagged", "en").contains("does not mean you have cancer"))
        XCTAssertTrue(Copy.text("voiceResearchFollowUp", "en").contains("Do not delay care"))
    }
    func testResearchDisclosuresAreAvailableInAllSupportedLanguages() {
        for key in ["voiceResearchTitle", "voiceResearchOffer", "voiceResearchLimits", "voiceResearchConsent",
                    "voiceResearchTask", "voiceResearchOpen", "voiceResearchStart", "voiceResearchCancel", "voiceResearchRecording",
                    "voiceResearchProcessing", "voiceResearchSkip", "voiceResearchUnavailable", "voiceResearchPermission",
                    "voiceResearchResultTitle", "voiceResearchFlagged", "voiceResearchNotFlagged",
                    "voiceResearchInconclusive", "voiceResearchFollowUp"] {
            XCTAssertEqual(Copy.strings[key]?.count, Copy.languages.count, key)
            for language in Copy.languages { XCTAssertNotEqual(Copy.text(key, language), key) }
        }
    }
}
