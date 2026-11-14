import XCTest
import EdgeCareCore
@testable import EdgeCareUI

@MainActor final class IntakeSafetyTests: XCTestCase {
    func testEmergencyAdviceAllowsRemainingQuestionsAndEncryptedReferral() async throws {
        let model = IntakeViewModel(source: .kiosk)
        model.clinicalProfile = ClinicalProfile(concernEnglish: "Cough", symptomsEnglish: ["Cough"], durationEnglish: "Two days")
        model.beginSafetyQuestions()
        XCTAssertEqual(model.safety.currentQuestion?.id, .urgentBreathing)
        model.answerSafetyQuestion(.yes)
        XCTAssertTrue(model.emergencyAdvicePending)
        XCTAssertEqual(model.step, 2)
        model.continueAfterEmergencyAdvice()
        XCTAssertFalse(model.emergencyAdvicePending)
        XCTAssertTrue(model.continuedAfterEmergencyAdvice)
        XCTAssertEqual(model.safety.currentQuestion?.id, .urgentGeneral)
        model.answerSafetyQuestion(.no)
        XCTAssertEqual(model.step, 3)
        model.answerSafetyQuestion(.no)
        XCTAssertEqual(model.step, 4)
        await model.continueFlow()
        XCTAssertEqual(model.step, 5)
        XCTAssertTrue(try XCTUnwrap(model.guidance).requiresEmergencyHelp)
        model.proceedToReferral()
        XCTAssertEqual(model.step, 6, "Emergency advice must not remove the referral path")
        let guidance = try XCTUnwrap(model.guidance)
        XCTAssertTrue(guidance.requiresEmergencyHelp)
        XCTAssertEqual(guidance.riskBand, .high)
        XCTAssertTrue(guidance.clinicianSummary.contains("Contact with emergency services has not been verified"))
        let draft = EnrollmentDraft(source: .kiosk, language: "en", concern: model.clinicalProfile.clinicianSummary,
            guidance: guidance, answers: model.referralAnswers, clinicalProfile: model.clinicalProfile)
        let record = try EnrollmentService().enroll(draft: draft, strokes: DemoData.signatureStrokes(), passcode: "1234", confirmation: "1234")
        XCTAssertTrue(record.symptoms.contains("emergency_symptom_reported"))
        XCTAssertEqual(record.riskBand, .high)
        XCTAssertTrue(record.freeTextSummary.contains("Patient chose to continue"))
        let privateData = try CommitmentCrypto.decrypt(XCTUnwrap(Data(base64Encoded: record.triageDetailEncrypted)),
            passcode: "1234", salt: XCTUnwrap(Data(base64Encoded: record.salt)))
        let detail = try XCTUnwrap(JSONSerialization.jsonObject(with: privateData) as? [String: Any])
        let answers = try XCTUnwrap(detail["answers"] as? [String: String])
        XCTAssertEqual(answers["urgentBreathing"], "yes")
        XCTAssertEqual(answers["urgentGeneral"], "no")
        XCTAssertEqual(answers["urgent_now"], "yes")
        XCTAssertNotNil(answers["emergency_advice_action"])
    }

    func testEmergencyDetectedInNarrativeAlsoAllowsReferral() async throws {
        let model = IntakeViewModel()
        model.concern = "I can't breathe"
        model.clinicalProfile = ClinicalProfile(concernEnglish: "Breathing difficulty", symptomsEnglish: ["Breathing difficulty"], durationEnglish: "Today")
        model.beginSafetyQuestions()
        while model.safety.currentQuestion != nil { model.answerSafetyQuestion(.no) }
        await model.continueFlow()
        XCTAssertTrue(try XCTUnwrap(model.guidance).requiresEmergencyHelp)
        model.proceedToReferral()
        XCTAssertEqual(model.step, 6)
        XCTAssertTrue(model.requiresEmergencyAdvice)
        XCTAssertTrue(model.continuedAfterEmergencyAdvice)
    }

    func testScreeningHelpDoesNotCreateEmergencyOrPersistenceAndBackNavigationWorks() async throws {
        let model = IntakeViewModel()
        model.selectedSymptoms = ["screening_letter"]
        model.beginSafetyQuestions()
        model.answerSafetyQuestion(.no)
        XCTAssertEqual(model.safety.currentQuestion?.id, .followScreening)
        model.answerSafetyQuestion(.yes)
        XCTAssertEqual(model.step, 4)
        XCTAssertEqual(model.urgent, "no")
        XCTAssertNil(model.persistent)
        model.goBack()
        XCTAssertEqual(model.step, 3)
        XCTAssertEqual(model.safety.currentQuestion?.id, .followScreening)
        model.goBack()
        XCTAssertEqual(model.step, 2)
        model.answerSafetyQuestion(.yes)
        XCTAssertTrue(model.emergencyAdvicePending)
        model.goBack()
        XCTAssertFalse(model.emergencyAdvicePending)
        XCTAssertEqual(model.safety.currentQuestion?.id, .urgentGeneral)
        model.answerSafetyQuestion(.no)
        model.answerSafetyQuestion(.yes)
        XCTAssertFalse(model.requiresEmergencyAdvice)
        model.reset()
        XCTAssertTrue(model.safety.answers.isEmpty)
        XCTAssertFalse(model.continuedAfterEmergencyAdvice)
        XCTAssertEqual(model.step, 0)
    }

    func testEverySafetyQuestionAndEmergencyChoiceHasFiveTranslations() {
        let keys = SafetyQuestionID.allCases.map(\.rawValue) + ["emergencyTitle", "emergencyAdvice", "emergencyContinueExplanation", "continueQuestionnaire", "continueReferral", "callEmergency", "tailoredSafety"]
        for key in keys {
            XCTAssertEqual(Copy.strings[key]?.count, Copy.languages.count, key)
            for language in Copy.languages {
                XCTAssertNotEqual(Copy.text(key, language), key)
                XCTAssertFalse(Copy.text(key, language).isEmpty)
            }
        }
    }

    func testUnchangedIntakeKeepsEmergencyAnswersWhenReturningFromConcern() {
        let model = IntakeViewModel()
        model.selectedSymptoms = ["persistent_cough"]
        model.beginSafetyQuestions()
        model.answerSafetyQuestion(.yes)
        model.continueAfterEmergencyAdvice()
        model.goBack()
        model.goBack()
        XCTAssertEqual(model.step, 1)
        model.beginSafetyQuestions()
        XCTAssertEqual(model.safety.answers["urgentBreathing"], "yes")
        XCTAssertTrue(model.requiresEmergencyAdvice)
        XCTAssertTrue(model.continuedAfterEmergencyAdvice)
        model.busy = true
        let state = model.safety
        model.goBack()
        model.answerSafetyQuestion(.no)
        XCTAssertEqual(model.safety, state, "An in-flight save or triage cannot navigate to stale answers")
    }
    func testExistingReferralLoadsEnglishProfileAndClearsUnlockedSessionOnReset() throws {
        let profile = ClinicalProfile(concernEnglish: "Cough", symptomsEnglish: ["Cough"], durationEnglish: "Two days")
        let draft = EnrollmentDraft(source: .kiosk, language: "fi", concern: "English summary\nPatient notes (original language): Yskää",
            guidance: TriageGuidance(message: "Synthetic guidance", symptoms: ["cough"]), letterText: "Synthetic letter", clinicalProfile: profile)
        let original = try EnrollmentService().enroll(draft: draft, strokes: DemoData.signatureStrokes(), passcode: "0123", confirmation: "0123")
        let edit = try EnrollmentService().unlock(record: original, passcode: "0123", strokes: DemoData.signatureStrokes())
        let model = IntakeViewModel(source: .kiosk)
        model.loadExistingReferral(edit)
        XCTAssertTrue(model.isUpdatingReferral)
        XCTAssertEqual(model.editingReferral?.original.id, original.id)
        XCTAssertEqual(model.clinicalProfile, profile)
        XCTAssertEqual(model.concern, "Yskää")
        XCTAssertEqual(model.letterText, "Synthetic letter")
        XCTAssertEqual(model.selectedSymptoms, ["persistent_cough"])
        XCTAssertEqual(model.language, "fi")
        XCTAssertEqual(model.step, 1)
        XCTAssertTrue(model.passcode.isEmpty)
        XCTAssertTrue(model.strokes.isEmpty)
        model.reset()
        XCTAssertFalse(model.isUpdatingReferral)
        XCTAssertNil(model.editingReferral)
    }
}
