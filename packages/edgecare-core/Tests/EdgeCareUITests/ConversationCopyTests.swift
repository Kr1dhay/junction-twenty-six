import XCTest
@testable import EdgeCareUI

final class ConversationCopyTests: XCTestCase {
    func testEchoCancellationWarningHasEverySupportedTranslation() {
        XCTAssertEqual(Copy.strings["headphonesRecommended"]?.count, Copy.languages.count)
        for language in Copy.languages {
            XCTAssertNotEqual(Copy.text("headphonesRecommended", language), "headphonesRecommended")
            XCTAssertFalse(Copy.text("headphonesRecommended", language).isEmpty)
        }
    }

    func testConnectingCopyHasTranslationsAndDoesNotClaimToProcessSpeech() {
        XCTAssertEqual(Copy.strings["conversationConnecting"]?.count, Copy.languages.count)
        for language in Copy.languages {
            XCTAssertNotEqual(Copy.text("conversationConnecting", language), "conversationConnecting")
        }
        XCTAssertNotEqual(Copy.text("conversationConnecting", "en"), Copy.text("saving", "en"))
    }

    func testManualCalibrationPromptsAreRemoved() {
        XCTAssertNil(Copy.strings["microphoneCalibrating"])
        XCTAssertNil(Copy.strings["recalibrateMicrophone"])
        XCTAssertNil(Copy.strings["microphoneNoisy"])
    }

    func testConsentDescribesGeminiOnlyNotTheRemovedElevenLabsVoicePath() {
        for language in Copy.languages {
            let disclosure = Copy.text("cloudDisclosure", language)
            XCTAssertTrue(disclosure.contains("Gemini"))
            XCTAssertFalse(disclosure.contains("ElevenLabs"))
        }
    }

    func testConversationControlsAndFeedbackRecoveryHaveEveryTranslation() {
        for key in ["conversationProcessing", "interruptReply", "conversationRepeatedInterruptions", "useTextInstead", "notYetProvided",
                    "voiceReadyTitle", "voiceConnectingTitle", "voiceListeningTitle", "voiceProcessingTitle", "voiceSpeakingTitle",
                    "voiceReadyHint", "voiceConnectingHint", "voiceProcessingHint", "voiceSpeakingHint", "latestDialogue",
                    "readingAloud", "stopReading", "preparingReadAloud", "aboutVoice"] {
            XCTAssertEqual(Copy.strings[key]?.count, Copy.languages.count, key)
            for language in Copy.languages {
                XCTAssertFalse(Copy.text(key, language).isEmpty)
                XCTAssertNotEqual(Copy.text(key, language), key)
            }
        }
    }
}
