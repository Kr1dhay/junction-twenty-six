import XCTest
@testable import EdgeCareCore

final class UkrainianTests: XCTestCase {
    func testLanguageAndSpeechLocale() {
        XCTAssertEqual(SupportedLanguage.resolve("uk-UA"), .uk)
        XCTAssertEqual(SupportedLanguage.uk.speechLocale, "uk-UA")
        XCTAssertEqual(SupportedLanguage.allCases.map(\.rawValue), ["en", "fi", "so", "ar", "uk", "ne"])
    }

    func testUkrainianEmergencyAndSymptomRouting() async throws {
        let urgent = try await OnDeviceTriageEngine().guidance(for: "У мене біль у грудях і важко дихати", language: "uk")
        XCTAssertTrue(urgent.requiresEmergencyHelp)
        XCTAssertTrue(urgent.message.contains("негайно телефонуйте 112"))
        let skin = try await OnDeviceTriageEngine().guidance(for: "Родимка на шкірі змінилася", language: "uk")
        XCTAssertEqual(skin.recommendedSpecialty, "dermatology")
        let questions = SafetyQuestionnaire.plan(originalConcern: "Кашляю, є ущільнення та лист про скринінг")
        XCTAssertTrue(questions.map(\.id).contains(.urgentBreathing))
        XCTAssertTrue(questions.map(\.id).contains(.followLump))
        XCTAssertTrue(questions.map(\.id).contains(.followScreening))
    }
}
