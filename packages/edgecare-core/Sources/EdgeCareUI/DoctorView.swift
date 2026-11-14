import SwiftUI
import EdgeCareCore

public struct DoctorRootView: View {
    @State private var app = AppSession(doctor: true)
    @State private var lookup = ""
    @State private var selected: ReferralRecord?
    @State private var lookupBusy = false
    @Environment(\.scenePhase) private var scenePhase
    public init() {}
    public var body: some View {
        NavigationStack {
            List {
                Section {
                    SessionBanner(connected: app.connected)
                    Text("Anonymous clinical demo. Signature matching is an experimental aid; use clinician judgement. No identity is collected.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Find a referral") {
                    TextField("Full referral ID", text: $lookup)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .font(.system(.body, design: .monospaced))
                    Button("Look up and cache") { Task { await find() } }.frame(minHeight: 44)
                        .disabled(UUID(uuidString: lookup.trimmingCharacters(in: .whitespacesAndNewlines)) == nil || lookupBusy || app.session == nil)
                    Text("Offline verification needs a referral and commitment cached on this device. Local demos on different devices do not share a registry.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Anonymous referrals") {
                    if app.records.isEmpty { Text("No cached referrals. Look up an ID or sync the shared demo.").foregroundStyle(.secondary) }
                    ForEach(app.records) { record in
                        NavigationLink { DoctorVerificationView(record: record, app: app) } label: { row(record) }
                    }
                }
                if let message = app.message { Section { Text(message).font(.footnote) } }
                Section { Button("Sync shared state") { Task { await app.sync() } }.disabled(app.busy) }
            }
            .navigationTitle("Doctor verification")
            .refreshable { await app.sync() }
            .navigationDestination(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { DoctorVerificationView(record: selected, app: app) }
            }
            .task { await app.start() }
            .onReceive(Timer.publish(every: 8, on: .main, in: .common).autoconnect()) { _ in
                guard scenePhase == .active, !app.busy else { return }
                Task { await app.refresh() }
            }
            .toolbar { ToolbarItem { Menu("Demo controls") { Toggle("Simulate offline", isOn: $app.simulateOffline) } } }
        }.tint(EdgeCareStyle.mulberry)
        .onChange(of: scenePhase) { _, phase in if phase != .active { lookup = "" } }
    }
    private func row(_ record: ReferralRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(String(record.id.prefix(8))).font(.headline.monospaced()); Spacer(); Text((app.wallet.first { $0.id == record.id })?.state.rawValue ?? record.status.rawValue).font(.caption.weight(.semibold)) }
            Text(record.recommendedSpecialty.replacingOccurrences(of: "_", with: " ")).font(.subheadline)
            Text(record.freeTextSummary).lineLimit(2).foregroundStyle(.secondary)
            Text("\(record.language.uppercased()) · \(record.riskBand.rawValue) demo priority · \(record.riskScore)/100").font(.caption)
        }.padding(.vertical, 8)
    }
    private func find() async {
        guard let session = app.session else { return }
        lookupBusy = true; defer { lookupBusy = false }
        do { selected = try await session.cacheReferral(id: lookup.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()); lookup = ""; await app.refresh() }
        catch { app.message = "Referral unavailable. Check the full ID and connection. Offline lookup needs an earlier cache. (\(error))" }
    }
}

public struct DoctorVerificationView: View {
    let record: ReferralRecord
    @Bindable var app: AppSession
    @State private var language: String
    @State private var passcode = ""
    @State private var strokes: [[SignaturePoint]] = []
    @State private var busy = false
    @State private var outcome: VerificationOutcome?
    @State private var error: String?
    @State private var lastActivity = Date()
    @StateObject private var speech = SpeechController()
    @Environment(\.scenePhase) private var scenePhase
    public init(record: ReferralRecord, app: AppSession) {
        self.record = record; self.app = app; _language = State(initialValue: record.language)
    }
    private func t(_ key: String) -> String { Copy.text(key, language) }
    public var body: some View {
        Form {
            Section("Referral") {
                Text(record.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text(record.freeTextSummary)
                LabeledContent("State", value: app.wallet.first(where: { $0.id == record.id })?.state.rawValue ?? record.status.rawValue)
                LabeledContent("Priority", value: "\(record.riskBand.rawValue) · \(record.riskScore)/100 (demo)")
                if record.letterScan.present { Text(record.letterScan.extractedText ?? "Letter noted; no readable text.") }
                if record.lesionPhoto.present { Text(record.lesionPhoto.assessment ?? "Skin concern noted. No medical image model available.") }
            }
            if let outcome {
                Section {
                    let walletState = app.wallet.first(where: { $0.id == record.id })?.state
                    let conflict = walletState == .conflict
                    let provisional = outcome.settlement == .provisional && walletState != .spent
                    Label(conflict ? "CONFLICT · shared registry rejected this use" : provisional ? "PROVISIONAL · awaiting registry" : outcome.settlement == .localDemo ? "VERIFIED · local demo only" : "VERIFIED · shared demo registry", systemImage: conflict ? "exclamationmark.octagon" : provisional ? "clock.badge.exclamationmark" : "checkmark.seal.fill")
                        .font(.title2.weight(.bold)).foregroundStyle(conflict ? Color.red : provisional ? Color.orange : Color.green)
                    Text(conflict ? "Another use was accepted first. This provisional use is not confirmed. Review the referral with the clinician." : !provisional && outcome.settlement == .provisional ? "The shared demo registry has now confirmed this use." : outcome.message)
                    if provisional { Text("Offline results do not guarantee single use across devices. First accepted spend wins; sync before treating the registry state as settled.") }
                    Button("Sync and refresh") { Task { await app.sync() } }.disabled(app.busy)
                    if let message = app.message { Text(message).font(.footnote) }
                }
            } else if record.status == .open && ![WalletState.spent, .provisionalSpend, .conflict].contains(app.wallet.first(where: { $0.id == record.id })?.state ?? .available) {
                Section {
                    Picker(t("language"), selection: $language) {
                        ForEach(Array(zip(Copy.languages, Copy.names)), id: \.0) { code, name in Text(name).tag(code) }
                    }
                    Text(t("handoff"))
                    PINField(title: t("enterPin"), value: $passcode)
                    Text(t("signature")).font(.headline)
                    SignaturePad(strokes: $strokes, language: language)
                    Button { speech.speak(t("signatureHint"), language: language) } label: { Label(t("read"), systemImage: "speaker.wave.2") }.frame(minHeight: 44)
                    if speech.unavailable { Text(t("speechUnavailable")).font(.footnote) }
                    Text(t("noReset")).font(.footnote).foregroundStyle(.secondary)
                }.environment(\.layoutDirection, language.lowercased().hasPrefix("ar") ? .rightToLeft : .leftToRight)
                Section {
                    Button { Task { await verify() } } label: {
                        if busy { ProgressView() } else { Label("Verify and mark single use", systemImage: "checkmark.shield") }
                    }.buttonStyle(.borderedProminent).tint(EdgeCareStyle.mulberry).frame(minHeight: 48)
                        .disabled(busy || passcode.count != 4 || strokes.flatMap { $0 }.count < 4 || app.session == nil)
                    Text("Success consumes this referral. Matching is demo-grade, not a validated identity check.").font(.footnote).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section("Synthetic demo") {
                    Text("Only for synthetic demo referrals enrolled with the sample. Code: 1234.").font(.caption)
                    Button("Use sample signature + 1234") { strokes = DemoData.signatureStrokes(); passcode = DemoData.passcode }
                }
            } else {
                Section { Label("This referral has been used, is pending settlement, or is no longer open. Check the latest shared state before proceeding.", systemImage: "lock.fill") }
            }
        }
        .navigationTitle("Verify referral")
        .onChange(of: passcode) { _, _ in lastActivity = Date() }
        .onChange(of: strokes) { _, _ in lastActivity = Date() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { clearSecrets() } }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            if Date().timeIntervalSince(lastActivity) > 120 { clearSecrets() }
        }
        .onDisappear { clearSecrets() }
    }
    private func clearSecrets() { passcode = ""; strokes = []; speech.stop() }
    private func verify() async {
        guard let session = app.session else { return }
        busy = true; error = nil
        let submittedPIN = passcode, submittedStrokes = strokes
        clearSecrets()
        defer { busy = false }
        do { outcome = try await session.verify(record: record, passcode: submittedPIN, strokes: submittedStrokes); await app.refresh() }
        catch { self.error = t("error") + " (\(error))" }
    }
}
