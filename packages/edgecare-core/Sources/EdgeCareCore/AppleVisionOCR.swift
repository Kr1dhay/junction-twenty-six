import Foundation
#if canImport(Vision)
@preconcurrency import Vision

/// Apple Vision text recognition runs locally. It reads letters; it does not assess skin or diagnose disease.
public struct AppleVisionOCREngine: VisionEngine {
    public init() {}
    public func interpret(image: Data) async throws -> String {
        guard !image.isEmpty else { throw CoreError.invalidResponse }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(data: image, options: [:]).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard !text.isEmpty else { throw CoreError.notFound }
        return text
    }
}
#else
public struct AppleVisionOCREngine: VisionEngine {
    public init() {}
    public func interpret(image: Data) async throws -> String { throw CoreError.notConfigured }
}
#endif
