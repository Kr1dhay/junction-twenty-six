import SwiftUI
import XCTest
@testable import EdgeCareUI
#if os(macOS)
import AppKit

@MainActor final class ThemeContrastTests: XCTestCase {
    private func components(_ color: Color, appearance: NSAppearance.Name) throws -> [Double] {
        var result: NSColor?
        try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            result = NSColor(color).usingColorSpace(.sRGB)
        }
        let rgb = try XCTUnwrap(result)
        return [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]
    }

    private func contrast(_ foreground: Color, _ background: Color, appearance: NSAppearance.Name) throws -> Double {
        func luminance(_ components: [Double]) -> Double {
            let linear = components.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let first = luminance(try components(foreground, appearance: appearance))
        let second = luminance(try components(background, appearance: appearance))
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    func testBodyAndAccentMeetNormalTextContrastInBothAppearances() throws {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            for surface in [EdgeCareStyle.canvas, EdgeCareStyle.card, EdgeCareStyle.surface, EdgeCareStyle.blush] {
                XCTAssertGreaterThanOrEqual(try contrast(EdgeCareStyle.graphite, surface, appearance: appearance), 4.5)
                XCTAssertGreaterThanOrEqual(try contrast(EdgeCareStyle.accent, surface, appearance: appearance), 4.5)
            }
            XCTAssertGreaterThanOrEqual(try contrast(.white, EdgeCareStyle.mulberry, appearance: appearance), 4.5)
        }
    }
}
#endif
