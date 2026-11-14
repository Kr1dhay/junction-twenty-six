import XCTest
@testable import EdgeCareCore

final class UkrainianTests: XCTestCase {
    func testLanguageAndSpeechLocale() {
        XCTAssertEqual(SupportedLanguage.resolve("uk-UA"), .uk)
        XCTAssertEqual(SupportedLanguage.resolve("ukr"), .uk)
        XCTAssertEqual(SupportedLanguage.uk.speechLocale, "uk-UA")
        XCTAssertEqual(SupportedLanguage.allCases.map(\.rawValue), ["en", "fi", "so", "ar", "uk", "ne"])
    }

    func testUkrainianEmergencyPhrases() async throws {
        for concern in ["Біль у грудях", "Біль в грудях", "Важко дихати", "Не можу дихати",
                        "Сильна кровотеча", "Втрата свідомості", "Людина непритомна"] {
            let guidance = try await OnDeviceTriageEngine().guidance(for: concern, language: "uk-UA")
            XCTAssertTrue(guidance.requiresEmergencyHelp, concern)
            XCTAssertTrue(guidance.message.contains("негайно телефонуйте 112"), concern)
        }
    }

    func testUkrainianSymptomsAndScreeningStayInEnglishClinicalFields() async throws {
        for (concern, symptom, question) in [
            ("Родимка на шкірі", "skin_change", SafetyQuestionID.followSkin),
            ("Нове ущільнення", "lump_or_swelling", .followLump),
            ("Кашляю вже місяць", "cough", .followCough),
            ("Незрозуміла кровотеча", "unexplained_bleeding", .followBleeding),
            ("Лист про скринінг", "screening_letter", .followScreening)
        ] {
            let guidance = try await OnDeviceTriageEngine().guidance(for: concern, language: "uk")
            XCTAssertTrue(guidance.symptoms.contains(symptom), concern)
            XCTAssertTrue(guidance.clinicianSummary.contains(symptom), concern)
            XCTAssertTrue(guidance.message.contains("не може діагностувати або виключити рак"), concern)
            XCTAssertTrue(SafetyQuestionnaire.plan(originalConcern: concern).map(\.id).contains(question), concern)
        }
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
