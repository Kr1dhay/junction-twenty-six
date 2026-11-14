import XCTest
@testable import EdgeCareCore

final class SafetyQuestionnaireTests: XCTestCase {
    func testSymptomPlans() {
        XCTAssertEqual(ids(["persistent_cough"]), [.urgentBreathing, .urgentGeneral, .followCough])
        XCTAssertEqual(ids(["skin_change"]), [.urgentGeneral, .followSkin])
        XCTAssertEqual(ids(["unexplained_bleeding"]), [.urgentBleeding, .urgentGeneral, .followBleeding])
        XCTAssertEqual(ids([]), [.urgentGeneral, .followGeneral])
    }
    func testScreeningHelpIsNotPersistenceOrEmergency() {
        var state = SafetyQuestionnaireState(plan: SafetyQuestionnaire.plan(selectedSymptoms: ["screening_letter"]))
        XCTAssertEqual(state.plan.map(\.id), [.urgentGeneral, .followScreening])
        state.answer(.no, for: .urgentGeneral)
        state.answer(.yes, for: .followScreening)
        XCTAssertTrue(state.isComplete)
        XCTAssertFalse(state.requiresEmergencyHelp)
        XCTAssertFalse(state.hasPersistentOrChangingSymptom)
    }
    func testStableDeduplicatedMultipleSymptoms() {
        let plan = SafetyQuestionnaire.plan(profile: ClinicalProfile(concernEnglish: "Skin, cough, blood, lump"), selectedSymptoms: ["skin_change", "persistent_cough", "lump", "unexplained_bleeding"])
        XCTAssertEqual(plan.map(\.id), [.urgentBreathing, .urgentBleeding, .urgentGeneral, .followSkin, .followLump, .followCough, .followBleeding])
        XCTAssertEqual(Set(plan.map(\.id)).count, plan.count)
    }
    func testOriginalConcernCombinesWithCanonicalAndSelectedSymptoms() {
        XCTAssertEqual(SafetyQuestionnaire.plan(originalConcern: "qufac").map(\.id), [.urgentBreathing, .urgentGeneral, .followCough])
        XCTAssertEqual(SafetyQuestionnaire.plan(profile: ClinicalProfile(concernEnglish: "a mole"), originalConcern: "qufac").map(\.id), [.urgentBreathing, .urgentGeneral, .followSkin, .followCough])
    }
    func testSelectedSkinAndOriginalBreathingConcern() {
        XCTAssertEqual(SafetyQuestionnaire.plan(selectedSymptoms: ["skin_change"], originalConcern: "I cannot breathe").map(\.id), [.urgentBreathing, .urgentGeneral, .followSkin])
    }
    func testEmergencyPersistsThroughContinuationAndOtherNegativeAnswers() {
        var state = SafetyQuestionnaireState(plan: SafetyQuestionnaire.plan(selectedSymptoms: ["persistent_cough"]))
        state.answer(.yes, for: .urgentBreathing)
        state.answer(.no, for: .urgentGeneral)
        state.answer(.unsure, for: .followCough)
        XCTAssertTrue(state.isComplete)
        XCTAssertTrue(state.requiresEmergencyHelp)
        XCTAssertFalse(state.hasPersistentOrChangingSymptom)
        XCTAssertEqual(state, SafetyQuestionnaireState(plan: state.plan, answers: state.portableAnswers))
        XCTAssertTrue(state.moveBack())
        XCTAssertEqual(state.currentQuestion?.id, .followCough)
        XCTAssertFalse(state.isComplete)
        XCTAssertTrue(state.moveBack())
        XCTAssertTrue(state.moveBack())
        XCTAssertFalse(state.moveBack())
        state.answer(.no, for: .urgentBreathing)
        XCTAssertFalse(state.requiresEmergencyHelp)
        state.reset(plan: SafetyQuestionnaire.plan())
        XCTAssertTrue(state.answers.isEmpty)
    }
    func testOnlyExplicitYesAndKnownQuestionAnswersCount() {
        var state = SafetyQuestionnaireState(plan: SafetyQuestionnaire.plan(), answers: ["urgentGeneral": "unknown", "urgentBleeding": "yes"])
        XCTAssertEqual(state.currentQuestion?.id, .urgentGeneral)
        state.answer(.unsure, for: .urgentGeneral)
        state.answer(.yes, for: .followGeneral)
        XCTAssertFalse(state.requiresEmergencyHelp)
        XCTAssertTrue(state.hasPersistentOrChangingSymptom)
    }
    private func ids(_ selected: Set<String>) -> [SafetyQuestionID] {
        SafetyQuestionnaire.plan(selectedSymptoms: selected).map(\.id)
    }
}
