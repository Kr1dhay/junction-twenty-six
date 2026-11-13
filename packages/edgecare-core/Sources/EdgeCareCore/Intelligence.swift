import Foundation
public struct TriageGuidance: Sendable { public let message: String }
public protocol TriageEngine: Sendable { func guidance(for text: String, language: String) async throws -> TriageGuidance }
public struct OnDeviceTriageEngine: TriageEngine {
    public init() {}
    public func guidance(for text: String, language: String) async throws -> TriageGuidance {
        TriageGuidance(message: "Demo scaffold: your concern is saved in this session. Clinical triage and translated guidance are not configured.")
    }
}
public struct GeminiTriageEngine: TriageEngine {
    public init() {}
    public func guidance(for text: String, language: String) async throws -> TriageGuidance { throw CoreError.notConfigured }
}
public protocol VisionEngine: Sendable { func interpret(image: Data) async throws -> String }
public struct MockVisionEngine: VisionEngine {
    public init() {}
    public func interpret(image: Data) async throws -> String { "Synthetic demo evidence. No medical image assessment has been performed." }
}
public struct NemotronVisionEngine: VisionEngine {
    public init() {}
    public func interpret(image: Data) async throws -> String { throw CoreError.notConfigured }
}
