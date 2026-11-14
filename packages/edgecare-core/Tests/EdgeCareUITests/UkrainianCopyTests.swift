import XCTest
import EdgeCareCore
@testable import EdgeCareUI

final class UkrainianCopyTests: XCTestCase {
    func testEveryCopyKeyHasAUkrainianTranslation() throws {
        let index = try XCTUnwrap(Copy.languages.firstIndex(of: "uk"))
        XCTAssertEqual(Copy.names[index], "Українська")
        XCTAssertEqual(Copy.text("yes", "uk"), "Так")
        XCTAssertEqual(Copy.text("no", "uk"), "Ні")
        XCTAssertEqual(Copy.languages, SupportedLanguage.allCases.map(\.rawValue))
        for (key, translations) in Copy.strings {
            XCTAssertEqual(translations.count, Copy.languages.count, key)
            guard translations.indices.contains(index) else { continue }
            XCTAssertFalse(translations[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
            XCTAssertEqual(Copy.text(key, "uk-UA"), translations[index], key)
            XCTAssertEqual(Copy.text(key, "ukr"), translations[index], key)
        }
        for question in SafetyQuestionID.allCases {
            XCTAssertNotNil(Copy.strings[question.rawValue], question.rawValue)
        }
    }
}
