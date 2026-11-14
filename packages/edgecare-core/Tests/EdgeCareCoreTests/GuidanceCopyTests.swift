import XCTest
@testable import EdgeCareCore

final class GuidanceCopyTests: XCTestCase {
    func testConciseGuidanceRetainsClinicalCautionAndRoutingMetadataInEveryLanguage() async throws {
        for (language, caution) in [
            ("en", "cannot diagnose or rule out cancer"), ("fi", "eivät totea eivätkä sulje pois syöpää"),
            ("so", "ma xaqiijin karaan mana diidi karaan kansar"), ("ar", "لا تشخّص السرطان ولا تستبعده"),
            ("uk", "не може діагностувати або виключити рак"), ("ne", "क्यान्सरको निदान गर्न वा यसलाई खारेज गर्न सक्दैन")
        ] {
            let guidance = try await OnDeviceTriageEngine().guidance(for: "new mole [urgent_now=no]", language: language)
            XCTAssertTrue(guidance.message.contains(caution))
            XCTAssertFalse(guidance.message.contains("score"))
            XCTAssertFalse(guidance.message.contains("demo"))
            XCTAssertEqual(guidance.riskScore, 75)
            XCTAssertEqual(guidance.riskBand, .high)
            XCTAssertEqual(guidance.recommendedSpecialty, "dermatology")
            XCTAssertFalse(guidance.requiresEmergencyHelp)
            XCTAssertFalse(guidance.sources.isEmpty)
        }
    }

    func testEmergencyAndScreeningLetterActionsAreNotRemoved() async throws {
        for language in ["en", "fi", "so", "ar", "uk", "ne"] {
            let emergency = try await OnDeviceTriageEngine().guidance(for: "[urgent_now=yes]", language: language)
            XCTAssertTrue(emergency.message.contains("112"))
            XCTAssertTrue(emergency.requiresEmergencyHelp)
            XCTAssertEqual(emergency.riskScore, 95)
            let letter = try await OnDeviceTriageEngine().guidance(for: "screening letter [urgent_now=no]", language: language)
            XCTAssertTrue(letter.symptoms.contains("screening_letter"))
        }
    }
}
