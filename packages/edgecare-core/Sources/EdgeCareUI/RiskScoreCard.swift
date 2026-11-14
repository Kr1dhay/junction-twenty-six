import SwiftUI
import EdgeCareCore

/// Large, colour-coded skin-check score with the reasons, the recommended action and cited statistics.
struct RiskScoreCard: View {
    let assessment: SkinAssessmentResult
    let language: String
    let compact: Bool
    private func t(_ key: String) -> String { Copy.text(key, language) }
    private var color: Color {
        switch assessment.band {
        case .low: return EdgeCareStyle.riskLow
        case .moderate: return EdgeCareStyle.riskModerate
        case .high: return EdgeCareStyle.riskHigh
        case .veryHigh: return EdgeCareStyle.riskVeryHigh
        }
    }
    private var bandKey: String { assessment.band.rawValue }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 20) {
            Text(t("riskTitle")).font(.headline).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: compact ? 16 : 28) {
                ZStack {
                    Circle().stroke(color.opacity(0.18), lineWidth: compact ? 12 : 16)
                    Circle().trim(from: 0, to: CGFloat(assessment.riskScore) / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: compact ? 12 : 16, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(assessment.riskScore)").font(.system(size: compact ? 44 : 64, weight: .bold, design: .rounded))
                            .foregroundStyle(color).monospacedDigit()
                        Text(t("riskOutOf")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: compact ? 130 : 180, height: compact ? 130 : 180)
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("risk_" + bandKey)).font(compact ? .title3.bold() : .title2.bold()).foregroundStyle(color)
                    Text(t("riskAction_" + bandKey)).font(compact ? .body : .title3)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(t("riskTitle")): \(assessment.riskScore) \(t("riskOutOf")). \(t("risk_" + bandKey)). \(t("riskAction_" + bandKey))")

            if assessment.scoringSource == "gemini" && !assessment.patientMessage.isEmpty {
                Text(assessment.patientMessage).font(.body)
            }
            if !assessment.keyFactors.isEmpty && SupportedLanguage.resolve(language) == .en {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("riskFactors")).font(.subheadline.weight(.semibold))
                    ForEach(assessment.keyFactors, id: \.self) { factor in
                        Label(factor, systemImage: "circle.fill").labelStyle(BulletLabelStyle(color: color)).font(.subheadline)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(t("riskFacts")).font(.subheadline.weight(.semibold))
                ForEach(SkinRiskFacts.facts(for: assessment.band, language: language), id: \.text) { fact in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.text).font(.subheadline)
                        Text("\(t("riskSource")): \(fact.source)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(EdgeCareStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Label(t("riskDisclaimer"), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
        }
        .padding(compact ? 16 : 24)
        .background(EdgeCareStyle.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(color.opacity(0.6), lineWidth: 2))
        .accessibilityIdentifier("skinRiskScoreCard")
    }
}

private struct BulletLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(color)
            configuration.title
        }
    }
}
