import XCTest
@testable import EdgeCareCore

final class SkinAssessmentTests: XCTestCase {
    private func result(score: Int, source: String = "gemini") throws -> SkinAssessmentResult {
        let json: [String: Any] = [
            "risk_score": score, "band": "low", "key_factors": ["Reported change", "Irregular border"],
            "patient_message": "Please see a doctor soon.", "clinician_note": "Irregular pigmented lesion.", "scoring_source": source,
            "cnn": ["probabilities": ["mel": 0.6, "nv": 0.4], "top": "mel", "top_probability": 0.6, "malignant_probability": 0.6, "source": "cnn", "model": "test"],
        ]
        return try JSONDecoder().decode(SkinAssessmentResult.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testBandAlwaysFollowsScoreAndClamps() throws {
        XCTAssertEqual(try result(score: 82).band, .veryHigh)   // server band "low" is ignored
        XCTAssertEqual(try result(score: 50).band, .high)
        XCTAssertEqual(try result(score: 25).band, .moderate)
        XCTAssertEqual(try result(score: 140).riskScore, 100)
        XCTAssertEqual(SkinRiskBand.from(score: 24), .low)
    }

    func testMergeSetsScoreSpecialtyAndClinicianSummary() async throws {
        let local = try await OnDeviceTriageEngine().guidance(for: "Something on my arm", language: "en")
        let merged = try result(score: 67).merged(into: local, language: "en")
        XCTAssertEqual(merged.riskScore, 67)
        XCTAssertEqual(merged.riskBand, .high)
        XCTAssertEqual(merged.recommendedSpecialty, "dermatology")
        XCTAssertTrue(merged.symptoms.contains("skin_change"))
        XCTAssertTrue(merged.message.hasPrefix("Please see a doctor soon."))
        XCTAssertTrue(merged.clinicianSummary.contains("67/100"))
        XCTAssertTrue(merged.label.contains("not a diagnosis"))
    }

    func testEmergencyGuidanceIsNeverDowngraded() async throws {
        let local = try await OnDeviceTriageEngine().guidance(for: "chest pain and a mole", language: "en")
        XCTAssertTrue(local.requiresEmergencyHelp)
        let merged = try result(score: 10).merged(into: local, language: "en")
        XCTAssertTrue(merged.requiresEmergencyHelp)
        XCTAssertEqual(merged.riskBand, .high)
        XCTAssertEqual(merged.riskScore, local.riskScore)
        XCTAssertEqual(merged.message, local.message)
    }

    func testEnglishFallbackMessageIsNotShownToNonEnglishPatients() async throws {
        let local = try await OnDeviceTriageEngine().guidance(for: "luomi", language: "fi")
        let merged = try result(score: 40, source: "fallback").merged(into: local, language: "fi")
        XCTAssertEqual(merged.message, local.message)
    }

    func testFactsAreLocalisedCitedAndOrderedByBand() {
        for language in ["en", "fi", "so", "ar", "uk", "ne"] {
            let facts = SkinRiskFacts.facts(for: .high, language: language)
            XCTAssertEqual(facts.count, 3)
            XCTAssertTrue(facts.allSatisfy { !$0.source.isEmpty })
            XCTAssertTrue(facts[0].text.contains("7"))
        }
        XCTAssertEqual(SkinRiskFacts.facts(for: .low, language: "en")[0].source, "NHS")
    }

    func testEnrollmentStoresAssessmentAndOmitsItWithoutPhoto() async throws {
        let guidance = try await OnDeviceTriageEngine().guidance(for: "mole", language: "en")
        let withPhoto = EnrollmentDraft(source: .kiosk, language: "en", concern: "mole", guidance: guidance, lesionPresent: true, lesionAssessment: "Skin photo demo score 70/100")
        XCTAssertEqual(withPhoto.lesionPhoto().assessment, "Skin photo demo score 70/100")
        let noAssessment = EnrollmentDraft(source: .kiosk, language: "en", concern: "mole", guidance: guidance, lesionPresent: true)
        XCTAssertEqual(noAssessment.lesionPhoto().assessment, EnrollmentDraft.unassessedPhoto)
        XCTAssertNil(EnrollmentDraft(source: .kiosk, language: "en", concern: "mole", guidance: guidance).lesionPhoto().assessment)
    }

    func testRequestEncodesSnakeCaseAndBase64() throws {
        let request = SkinAssessmentRequest(consent: true, language: "fi", image: Data([1, 2, 3]), profile: nil, answers: ["followSkin": "yes"], concern: "x")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(object["image_base64"] as? String, "AQID")
        XCTAssertEqual(object["image_mime"] as? String, "image/jpeg")
    }
}
