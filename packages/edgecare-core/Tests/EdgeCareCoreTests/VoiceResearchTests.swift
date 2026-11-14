import XCTest
@testable import EdgeCareCore

final class VoiceResearchTests: XCTestCase {
    private func assessment(_ outcome: VoiceResearchAssessment.Outcome = .notFlagged) -> VoiceResearchAssessment {
        VoiceResearchAssessment(outcome: outcome, assessedAt: "2026-11-14T12:00:00.000Z",
            modelID: "synthetic-test-only", modelVersion: "test-1", sampleDurationSeconds: 6)
    }
    private func draft(_ result: VoiceResearchAssessment?) -> EnrollmentDraft {
        EnrollmentDraft(source: .kiosk, language: "en", concern: "Synthetic hoarseness",
            guidance: TriageGuidance(message: "Arrange clinician review.", riskBand: .high, riskScore: 75,
                                    recommendedSpecialty: "ent", requiresEmergencyHelp: true), voiceResearch: result)
    }
    func testRelevantReportedSymptomsOfferTheTaskWithoutDiagnosing() {
        for text in ["My voice is changing", "I have hoarseness", "I have difficulty swallowing", "There is a lump in my neck",
                     "My throat pain persists", "I have a sore throat", "Swallowing is painful", "Pain with swallowing",
                     "ääni on käheä", "بحة في الصوت", "осиплость голоса", "cod xabeeb"] {
            XCTAssertTrue(VoiceResearchEligibility.shouldOffer(profile: ClinicalProfile(concernEnglish: text)), text)
        }
        XCTAssertFalse(VoiceResearchEligibility.shouldOffer(profile: ClinicalProfile(concernEnglish: "An ankle sprain")))
    }
    func testEnglishNegationAndFamilyHistoryAreNotSelfReportedSymptoms() {
        for text in ["I have no hoarseness", "Denies dysphonia", "My mother had throat cancer", "No voice changes"] {
            XCTAssertFalse(VoiceResearchEligibility.shouldOffer(profile: ClinicalProfile(concernEnglish: text)), text)
        }
        XCTAssertTrue(VoiceResearchEligibility.shouldOffer(profile: ClinicalProfile(concernEnglish: "No fever but I have hoarseness")))
    }
    func testResultRoundTripsButContainsNoAudioOrCancerProbability() throws {
        let result = assessment()
        XCTAssertTrue(result.isValid)
        let encoded = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(VoiceResearchAssessment.self, from: encoded), result)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["outcome", "assessed_at", "model_id", "model_version", "sample_duration_seconds", "research_only"])
    }
    func testLegacyRecordsDecodeAndNewResultsPersistWithoutChangingTriage() throws {
        let service = EnrollmentService()
        let legacy = try service.enroll(draft: draft(nil), strokes: DemoData.signatureStrokes(), passcode: "1234", confirmation: "1234")
        XCTAssertNil(try JSONDecoder().decode(ReferralRecord.self, from: JSONEncoder().encode(legacy)).voiceResearch)
        for outcome in [VoiceResearchAssessment.Outcome.flagged, .notFlagged, .inconclusive] {
            let record = try service.enroll(draft: draft(assessment(outcome)), strokes: DemoData.signatureStrokes(), passcode: "1234", confirmation: "1234")
            XCTAssertEqual(record.voiceResearch, assessment(outcome))
            XCTAssertEqual(record.riskScore, 75)
            XCTAssertEqual(record.riskBand, .high)
            XCTAssertEqual(record.recommendedSpecialty, "ent")
            XCTAssertEqual(record.patientLanguageSummary, "Arrange clinician review.")
        }
    }
    func testUpdatingReferralPreservesExistingResearchIfNoNewTaskIsTaken() throws {
        let service = EnrollmentService()
        let original = try service.enroll(draft: draft(assessment(.flagged)), strokes: DemoData.signatureStrokes(), passcode: "1234", confirmation: "1234")
        let unlocked = try service.unlock(record: original, passcode: "1234", strokes: DemoData.signatureStrokes())
        let update = try service.prepareUpdate(session: unlocked, draft: draft(nil))
        XCTAssertTrue(update.preservesIdentity)
        XCTAssertEqual(update.record.voiceResearch, original.voiceResearch)
    }
    func testMalformedResultCannotBeEnrolled() throws {
        let bad = VoiceResearchAssessment(outcome: .notFlagged, assessedAt: "invalid", modelID: "", modelVersion: "", sampleDurationSeconds: .nan)
        XCTAssertFalse(bad.isValid)
        XCTAssertThrowsError(try EnrollmentService().enroll(draft: draft(bad), strokes: DemoData.signatureStrokes(), passcode: "1234", confirmation: "1234"))
    }
    func testNoConsentPreventsAnyClientUpload() async {
        let client = ConsentGatedVoiceClient(baseURL: URL(string: "https://example.invalid")!, configuration: .connectedDemo)
        do {
            _ = try await client.assessResearchVoice(audio: Data([1]), consent: false)
            XCTFail("Consent must be enforced before transport")
        } catch { XCTAssertEqual(error as? CoreError, .consentRequired) }
    }
}
