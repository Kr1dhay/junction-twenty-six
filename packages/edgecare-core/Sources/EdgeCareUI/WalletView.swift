import SwiftUI
import EdgeCareCore

public struct ReferralHandoff: View {
    public let record: ReferralRecord
    public let language: String
    public init(record: ReferralRecord, language: String = "en") { self.record = record; self.language = language }
    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(Copy.text("anonymous", language), systemImage: "lock.shield")
            Text(record.id).font(.system(.headline, design: .monospaced)).textSelection(.enabled)
                .accessibilityLabel("Referral ID: \(record.id)")
            ShareLink(item: record.id) { Label(Copy.text("referralID", language), systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
            Text(Copy.text("handoff", language))
            Text(record.patientLanguageSummary).font(.body)
            LabeledContent(Copy.text("expires", language), value: String(record.expiresAt.prefix(10)))
        }
    }
}

public struct WalletView: View {
    @Bindable var app: AppSession
    public let language: String
    public init(app: AppSession, language: String = "en") { self.app = app; self.language = language }
    public var body: some View {
        List {
            Section { SessionBanner(connected: app.connected, language: language) }
            if app.wallet.isEmpty { Text(Copy.text("empty", language)).foregroundStyle(.secondary) }
            ForEach(app.wallet) { entry in
                NavigationLink {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            ReferralHandoff(record: entry.record, language: language)
                            Text(Copy.text(entry.state.rawValue, language)).font(.caption).foregroundStyle(.secondary)
                            if entry.state == .pendingEnrollment || entry.state == .provisionalSpend {
                                Text(Copy.text("pending", language))
                            }
                        }.padding(24).frame(maxWidth: 720)
                    }.navigationTitle(Copy.text("wallet", language))
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(entry.record.id.prefix(8))).font(.headline.monospaced())
                        Text(entry.record.recommendedSpecialty.replacingOccurrences(of: "_", with: " "))
                        Label(Copy.text(entry.state.rawValue, language), systemImage: entry.state == .spent ? "checkmark.seal" : "lock.shield").font(.caption)
                    }.padding(.vertical, 8)
                }
            }
            if let message = app.message { Section { Text(message).font(.footnote) } }
            Section { Button(Copy.text("sync", language)) { Task { await app.sync() } }.disabled(app.busy || app.session == nil) }
        }
        .navigationTitle(Copy.text("wallet", language))
        .task { await app.refresh() }
        .refreshable { await app.sync() }
        .environment(\.layoutDirection, language.lowercased().hasPrefix("ar") ? .rightToLeft : .leftToRight)
    }
}
