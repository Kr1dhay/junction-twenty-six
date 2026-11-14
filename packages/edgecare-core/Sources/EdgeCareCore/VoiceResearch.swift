import Foundation

/// An experimental model observation, never a diagnosis, probability, or triage score.
public struct VoiceResearchAssessment: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case flagged, notFlagged = "not_flagged", inconclusive }
    public let outcome: Outcome
    public let assessedAt: String
    public let modelID: String
    public let modelVersion: String
    public let sampleDurationSeconds: Double
    public let researchOnly: Bool
    public init(outcome: Outcome, assessedAt: String, modelID: String, modelVersion: String, sampleDurationSeconds: Double) {
        self.outcome = outcome; self.assessedAt = assessedAt; self.modelID = modelID
        self.modelVersion = modelVersion; self.sampleDurationSeconds = sampleDurationSeconds; researchOnly = true
    }
    public var isValid: Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: assessedAt) ?? ISO8601DateFormatter().date(from: assessedAt)
        return researchOnly && !modelID.isEmpty && modelID.count <= 120 && !modelVersion.isEmpty && modelVersion.count <= 120
        && date != nil
        && sampleDurationSeconds.isFinite && (2...12).contains(sampleDurationSeconds)
    }
    enum CodingKeys: String, CodingKey {
        case outcome, assessedAt = "assessed_at", modelID = "model_id", modelVersion = "model_version"
        case sampleDurationSeconds = "sample_duration_seconds", researchOnly = "research_only"
    }
}

public struct VoiceResearchAvailability: Decodable, Sendable {
    public let available: Bool
}

/// Matches reported words only to OFFER an optional task; never infers cancer.
/// The patient must still confirm that the symptoms concern them and consent.
public enum VoiceResearchEligibility {
    public static func shouldOffer(profile: ClinicalProfile, originalConcern: String = "") -> Bool {
        let text = ([profile.concernEnglish] + profile.symptomsEnglish + [profile.additionalContextEnglish, originalConcern])
            .joined(separator: ". ").lowercased()
            .replacingOccurrences(of: #"\b(but|however)\b"#, with: ".", options: .regularExpression)
        let patterns = [
            #"hoars\w*|dysphoni\w*|raspy voice|husky voice|voice (?:is |has )?(?:chang\w*|loss|problem)|lost (?:my )?voice|change in (?:my |the )?voice|sore throat|throat (?:pain|lump|swelling|cancer)|laryngeal|larynx"#,
            #"(?:pain|difficulty|trouble|painful) (?:when |with )?swallowing|swallowing (?:is )?(?:painful|difficult)|dysphagi\w*|neck (?:lump|swelling)|lump (?:in|on) (?:my |the )?(?:neck|throat)"#,
            #"kähe\w*|äänen muutos|kurkkukipu|nielemisvaikeu\w*|kyhmy kaulassa"#,
            #"cod xabeeb|codka oo isbedde\w*|liqid\w*|cune xanuun"#,
            #"بحة|بحّة|تغير الصوت|صعوبة البلع|ألم الحلق|كتلة في الرقبة"#,
            #"осип\w*|охрип\w*|изменени\w* голос\w*|затруднен\w* глотани\w*|боль в горле"#
        ]
        for clause in text.components(separatedBy: CharacterSet(charactersIn: ".!?;\n")) {
            let family = clause.range(of: #"\b(my mother|my father|my sister|my brother|family history)\b"#, options: .regularExpression) != nil
            if family && clause.range(of: #"\b(i have|my voice|my throat|my neck)\b"#, options: .regularExpression) == nil { continue }
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(in: clause, range: NSRange(clause.startIndex..., in: clause)) {
                    guard let range = Range(match.range, in: clause) else { continue }
                    let prefix = String(clause[..<range.lowerBound].suffix(70))
                    let negated = prefix.range(of: #"\b(no|without|deny|denies|denied|don't have|do not have|not experiencing|no longer have)\s+(?:\w+\s+){0,4}$"#, options: .regularExpression) != nil
                    if !negated { return true }
                }
            }
        }
        return false
    }
}

extension ConsentGatedVoiceClient {
    public func voiceResearchAvailability() async throws -> VoiceResearchAvailability {
        try await researchAvailability()
    }
    public func assessResearchVoice(audio: Data, consent: Bool) async throws -> VoiceResearchAssessment {
        guard consent else { throw CoreError.consentRequired }
        guard !audio.isEmpty, audio.count <= 512 * 1024 else { throw CoreError.invalidConfiguration }
        return try await researchAssessment(audio: audio)
    }
}
