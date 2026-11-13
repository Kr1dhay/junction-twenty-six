import Foundation
public struct SignaturePoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let time: Double
    public let pressure: Double?
    public init(x: Double, y: Double, time: Double = 0, pressure: Double? = nil) {
        self.x = x; self.y = y; self.time = time; self.pressure = pressure
    }
}
public struct SignatureTemplate: Codable, Equatable, Sendable {
    public let points: [SignaturePoint]
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
public enum SignatureMatcher {
    // Demo threshold; not a validated biometric operating point.
    public static let threshold = 0.85
    public static func extract(_ strokes: [[SignaturePoint]]) throws -> SignatureTemplate {
        let points = strokes.flatMap { $0 }
        guard points.count >= 4, points.count <= 4096,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.time.isFinite }) else { throw CoreError.invalidSignature }
        let minX = points.map(\.x).min()!, minY = points.map(\.y).min()!
        let scale = max(points.map(\.x).max()! - minX, points.map(\.y).max()! - minY)
        guard scale > 0.001 else { throw CoreError.invalidSignature }
        let normalized = (0..<32).map { index in
            let position = Double(index) * Double(points.count - 1) / 31
            let lower = Int(position), upper = min(lower + 1, points.count - 1), fraction = position - Double(lower)
            return SignaturePoint(x: (points[lower].x + (points[upper].x - points[lower].x) * fraction - minX) / scale,
                                  y: (points[lower].y + (points[upper].y - points[lower].y) * fraction - minY) / scale)
        }
        return SignatureTemplate(points: normalized)
    }
    public static func similarity(_ lhs: SignatureTemplate, _ rhs: SignatureTemplate) -> Double {
        guard lhs.points.count == 32, rhs.points.count == 32 else { return 0 }
        var previous = [Double](repeating: .infinity, count: 33); previous[0] = 0
        for left in lhs.points {
            var current = [Double](repeating: .infinity, count: 33)
            for (index, right) in rhs.points.enumerated() {
                let cost = hypot(left.x - right.x, left.y - right.y)
                guard cost.isFinite else { return 0 }
                current[index + 1] = cost + min(previous[index + 1], current[index], previous[index])
            }
            previous = current
        }
        return max(0, 1 - previous[32] / 32)
    }
}
