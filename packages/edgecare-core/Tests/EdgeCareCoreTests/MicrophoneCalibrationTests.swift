import XCTest
@testable import EdgeCareCore

final class MicrophoneCalibrationTests: XCTestCase {
    private func pcm(_ amplitude: Int16, frames: Int = 800) -> Data {
        var data = Data()
        for _ in 0..<frames {
            let value = UInt16(bitPattern: amplitude)
            data.append(UInt8(value & 255)); data.append(UInt8(value >> 8))
        }
        return data
    }
    private func calibrated(_ amplitude: Int16) throws -> CalibratedMicrophoneInput {
        var input = CalibratedMicrophoneInput()
        let quiet = pcm(amplitude), power = try XCTUnwrap(PCM16Audio.power(quiet))
        for _ in 0..<20 { _ = input.process(quiet, power: power) }
        XCTAssertTrue(input.calibration.isComplete)
        return input
    }
    func testMeasuresAmbientLevelAndIgnoresBriefClicksAndInvalidSamples() {
        var calibration = MicrophoneCalibration()
        calibration.sample(power: .nan, duration: 1)
        calibration.sample(power: -30, duration: .infinity)
        calibration.sample(power: -30, duration: -1)
        XCTAssertFalse(calibration.isComplete)
        for tick in 0..<10 { calibration.sample(power: tick == 2 ? -5 : -55, duration: 0.1) }
        XCTAssertTrue(calibration.isComplete)
        XCTAssertEqual(calibration.noiseFloor, -55)
        XCTAssertEqual(calibration.speechThreshold, -45)
        calibration.sample(power: -5, duration: 1)
        XCTAssertEqual(calibration.noiseFloor, -55, "Speech after calibration must not train the ambient floor")
    }
    func testRecalibrationReplacesPreviousRoomLevelAndWarnsAboutLoudBackground() {
        var calibration = MicrophoneCalibration()
        for _ in 0..<10 { calibration.sample(power: -60, duration: 0.1) }
        XCTAssertEqual(calibration.speechThreshold, -50)
        calibration = MicrophoneCalibration()
        for _ in 0..<10 { calibration.sample(power: -25, duration: 0.1) }
        XCTAssertTrue(calibration.isNoisy)
        XCTAssertEqual(calibration.speechThreshold, -15)
        calibration = MicrophoneCalibration()
        for _ in 0..<10 { calibration.sample(power: -1, duration: 0.1) }
        XCTAssertGreaterThan(calibration.speechThreshold, 0, "Clipped background must prompt a quieter input, not become constant speech")
    }
    func testConstantRoomNoiseThatExceededTheOldFixedThresholdIsNotPatientSpeech() throws {
        var input = try calibrated(520) // About -36 dB, above the old -42 dB cutoff.
        let noise = pcm(520), power = try XCTUnwrap(PCM16Audio.power(noise))
        XCTAssertGreaterThan(power, -42)
        for _ in 0..<100 {
            let frame = try XCTUnwrap(input.process(noise, power: power))
            XCTAssertFalse(frame.speechDetected)
            XCTAssertTrue(frame.audio.allSatisfy { $0 == 0 })
        }
    }
    func testQuietSpeechIsRecognizedAndPreRollPreservesTheFirstSyllable() throws {
        var input = try calibrated(32) // Quiet room, about -60 dB.
        let voice = pcm(200), power = try XCTUnwrap(PCM16Audio.power(voice))
        XCTAssertLessThan(power, -42, "This voice would miss the old hard-coded cutoff")
        let onset = try XCTUnwrap(input.process(voice, power: power))
        XCTAssertFalse(onset.speechDetected, "One brief transient is not a turn")
        let speech = try XCTUnwrap(input.process(voice, power: power))
        XCTAssertTrue(speech.speechDetected)
        XCTAssertEqual(Data(speech.audio.suffix(voice.count * 2)), voice + voice)
        for _ in 0..<10 { _ = input.process(pcm(32), power: -60) }
        let silence = try XCTUnwrap(input.process(pcm(32), power: -60))
        XCTAssertFalse(silence.speechDetected)
        XCTAssertTrue(silence.audio.allSatisfy { $0 == 0 })
    }
    func testSpeakerPlaybackCannotTrainCalibrationOrBecomeFreshPatientSpeech() throws {
        var input = CalibratedMicrophoneInput()
        let echo = pcm(16000), power = try XCTUnwrap(PCM16Audio.power(echo))
        for _ in 0..<30 {
            let frame = try XCTUnwrap(input.process(echo, power: power, suppress: true))
            XCTAssertFalse(frame.speechDetected)
            XCTAssertTrue(frame.audio.allSatisfy { $0 == 0 })
        }
        XCTAssertFalse(input.calibration.isComplete)
        input = try calibrated(32)
        let floor = input.calibration.noiseFloor
        for _ in 0..<20 { _ = input.process(echo, power: power, suppress: true) }
        XCTAssertEqual(input.calibration.noiseFloor, floor)
        let quiet = try XCTUnwrap(input.process(pcm(32), power: -60))
        XCTAssertFalse(quiet.speechDetected)
        XCTAssertTrue(quiet.audio.allSatisfy { $0 == 0 })
        XCTAssertNil(input.process(Data([1]), power: -20))
        XCTAssertNil(input.process(Data(), power: -20))
        XCTAssertNil(input.process(Data(repeating: 0, count: 32770), power: -20))
    }
    func testLegacyTurnDetectionUsesTheSameMeasuredThreshold() {
        var calibration = MicrophoneCalibration()
        for _ in 0..<10 { calibration.sample(power: -36, duration: 0.1) }
        var detector = SpeechTurnDetector(threshold: calibration.speechThreshold)
        for tick in 1..<120 { XCTAssertEqual(detector.sample(power: -36, elapsed: Double(tick) / 10), .listening) }
        XCTAssertFalse(detector.hasSpeech)
        XCTAssertEqual(detector.sample(power: -36, elapsed: 12), .noSpeech)
    }
}
