import SwiftUI
import EdgeCareCore

public struct DoctorRootView: View {
    @State private var app = AppSession(doctor: true)
    @State private var lookupMethod = "id"
    @State private var lookup = ""
    @State private var lookupPIN = ""
    @State private var lookupStrokes: [[SignaturePoint]] = []
    @State private var lookupLanguage = "en"
    @State private var matches: [VerifiedReferralMatch] = []
    @State private var searchedLocalOnly = false
    @State private var lookupMessage: String?
    @State private var selected: ReferralRecord?
    @State private var selectedVerification: PatientVerification?
    @State private var lookupBusy = false
    @State private var lookupTask: Task<Void, Never>?
    @State private var lookupGeneration = 0
    @State private var lastLookupActivity = Date()
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG && os(iOS)
    /// Simulator automation only: `EDGECARE_DEBUG_CONSULT=<referral id prefix|first>` opens the
    /// consultation directly, skipping signature verification. Never compiled into release builds.
    @State private var debugConsult: ReferralRecord?
    @State private var debugConsultOpened = false
    #endif
    public init() {}
    public var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        EdgeCareWordmark(size: 20)
                        Text("Confirm a referral").font(.title2.weight(.bold)).foregroundStyle(EdgeCareStyle.graphite).accessibilityAddTraits(.isHeader)
                        SessionBanner(connected: app.connected)
                        Text("Anonymous clinical demo. Signature matching is an experimental aid; use clinician judgement. No identity is collected.")
                            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 4)
                }
                Section("Find a patient referral") {
                    Picker("Find using", selection: $lookupMethod) {
                        Text("Referral ID").tag("id")
                        Text("Signature + code").tag("signature")
                    }.pickerStyle(.segmented).disabled(lookupBusy)
                    if lookupMethod == "id" {
                        TextField("Enter full referral ID", text: $lookup)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                            .font(.system(.body, design: .monospaced))
                            .disabled(lookupBusy)
                        Button("Find referral") { beginLookup() }.buttonStyle(.edgeCarePrimary)
                            .disabled(UUID(uuidString: lookup.trimmingCharacters(in: .whitespacesAndNewlines)) == nil || lookupBusy || app.session == nil)
                    } else {
                        Picker("Patient language", selection: $lookupLanguage) {
                            ForEach(Array(zip(Copy.languages, Copy.names)), id: \.0) { code, name in Text(name).tag(code) }
                        }.disabled(lookupBusy)
                        PINField(title: Copy.text("enterPin", lookupLanguage), value: $lookupPIN).disabled(lookupBusy)
                        Text(Copy.text("signature", lookupLanguage)).font(.headline)
                        SignaturePad(strokes: $lookupStrokes, language: lookupLanguage).id(lookupGeneration).disabled(lookupBusy)
                        Button("Find with signature + code") { beginLookup() }.buttonStyle(.edgeCarePrimary)
                            .disabled(lookupPIN.count != 4 || lookupStrokes.flatMap { $0 }.count < 4 || lookupBusy || app.session == nil)
                        Text("No referral ID needed. The signature and code are checked on this phone against clinician-accessible referrals. They are not uploaded.").font(.caption).foregroundStyle(.secondary)
                        Text("Searches unexpired referrals, including referrals already used. Offline search covers only this phone's saved referrals.").font(.caption).foregroundStyle(.secondary)
                    }
                    if lookupBusy {
                        ProgressView("Finding referrals…")
                        Button("Cancel lookup", role: .cancel) { cancelLookup() }
                    }
                    if let lookupMessage { Text(lookupMessage).font(.footnote).foregroundStyle(.secondary) }
                }
                if !matches.isEmpty {
                    Section("Matching referrals") {
                        Text("More than one referral matched. Choose the referral for this visit; matching does not establish a unique patient identity.").font(.footnote).foregroundStyle(.secondary)
                        if searchedLocalOnly { Text("Results from this device only.").font(.caption) }
                        ForEach(matches) { match in
                            Button { open(match) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    row(match.record)
                                    Text(match.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain).contentShape(Rectangle())
                        }
                    }
                }
                Section("Anonymous referrals") {
                    if app.records.isEmpty { Text("No saved referrals. Enter an ID, use signature + code, or sync.").foregroundStyle(.secondary) }
                    ForEach(app.records) { record in
                        NavigationLink { DoctorVerificationView(record: record, app: app) } label: { row(record) }
                    }
                }
                if let message = app.message { Section { Text(message).font(.footnote) } }
                Section { Button("Sync shared state") { Task { await app.sync() } }.disabled(app.busy || lookupBusy) }
            }
            .edgeCareListBackground()
            .navigationTitle("Doctor verification")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .refreshable { if !lookupBusy { await app.sync() } }
            .navigationDestination(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil; selectedVerification = nil; matches = [] } })) {
                if let selected { DoctorVerificationView(record: selected, app: app, verification: selectedVerification) }
            }
            .task { await app.start() }
            .onReceive(Timer.publish(every: 8, on: .main, in: .common).autoconnect()) { _ in
                guard scenePhase == .active else { return }
                if Date().timeIntervalSince(lastLookupActivity) > 120 { cancelLookup() }
                guard !app.busy, !lookupBusy else { return }
                Task { await app.refresh() }
            }
            .toolbar { ToolbarItem { Menu("Demo controls") { Toggle("Simulate offline", isOn: $app.simulateOffline) } } }
        }.tint(EdgeCareStyle.accent)
        .onChange(of: lookupMethod) { _, _ in cancelLookup(); lookupMessage = nil }
        .onChange(of: lookupPIN) { _, value in lastLookupActivity = Date(); if !value.isEmpty { matches = [] } }
        .onChange(of: lookupStrokes) { _, value in lastLookupActivity = Date(); if !value.isEmpty { matches = [] } }
        .onChange(of: lookup) { _, _ in lastLookupActivity = Date() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelLookup(); selected = nil; selectedVerification = nil }
        }
        .onDisappear { cancelLookup() }
        #if DEBUG && os(iOS)
        .onChange(of: app.records) { _, records in
            guard !debugConsultOpened, let wanted = ProcessInfo.processInfo.environment["EDGECARE_DEBUG_CONSULT"], !wanted.isEmpty else { return }
            guard let record = wanted == "first" ? records.first(where: { $0.status == .open }) ?? records.first : records.first(where: { $0.id.hasPrefix(wanted.lowercased()) }) else { return }
            debugConsultOpened = true; debugConsult = record
        }
        .fullScreenCover(item: $debugConsult) { record in
            if let session = app.session { ConsultationView(record: record, session: session) }
        }
        #endif
    }
    private func row(_ record: ReferralRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(String(record.id.prefix(8))).font(.headline.monospaced()).foregroundStyle(EdgeCareStyle.graphite); Spacer(); EdgeCareStatusPill((app.wallet.first { $0.id == record.id })?.state.rawValue ?? record.status.rawValue) }
            Text(record.recommendedSpecialty.replacingOccurrences(of: "_", with: " ")).font(.subheadline)
            Text(record.clinicalDescription).lineLimit(2).foregroundStyle(.secondary)
            Text("\(record.language.uppercased()) · \(record.riskBand.rawValue) demo priority · \(record.riskScore)/100").font(.caption)
        }.padding(.vertical, 8)
    }
    private func clearLookupSecrets() { lookupPIN = ""; lookupStrokes = [] }
    private func cancelLookup() {
        lookupGeneration += 1; lookupTask?.cancel(); lookupTask = nil
        lookupBusy = false; matches = []; lookup = ""; clearLookupSecrets()
    }
    private func open(_ match: VerifiedReferralMatch) {
        selectedVerification = match.verification; selected = match.record
        matches = []; clearLookupSecrets(); lastLookupActivity = Date()
    }
    private func beginLookup() {
        guard let session = app.session, !lookupBusy else { return }
        let method = lookupMethod, id = lookup.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pin = lookupPIN, strokes = lookupStrokes
        cancelLookup(); lookupBusy = true; lookupMessage = nil; searchedLocalOnly = false
        lastLookupActivity = Date()
        let current = lookupGeneration
        lookupTask = Task {
            defer { if current == lookupGeneration { lookupBusy = false; lookupTask = nil } }
            do {
                if method == "id" {
                    let record = try await session.cacheReferral(id: id)
                    await app.refreshCachedRecords()
                    guard !Task.isCancelled, current == lookupGeneration, scenePhase == .active else { return }
                    selectedVerification = nil; selected = record
                } else {
                    let result = try await session.findReferrals(passcode: pin, strokes: strokes)
                    await app.refreshCachedRecords()
                    guard !Task.isCancelled, current == lookupGeneration, scenePhase == .active else { return }
                    searchedLocalOnly = result.searchedLocalOnly
                    if result.matches.count == 1, let match = result.matches.first { open(match) }
                    else {
                        matches = result.matches
                        if matches.isEmpty {
                            lookupMessage = result.searchedLocalOnly
                                ? "No matching unexpired referral saved on this phone. Connect and search again, or use the referral ID."
                                : "No matching unexpired referral found. Check the code and signature, or use the referral ID."
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled, current == lookupGeneration else { return }
                lookupMessage = (error as? CoreError)?.userMessage ?? "Lookup could not finish. Check the connection and try again."
            }
        }
    }
}

public struct DoctorVerificationView: View {
    let record: ReferralRecord
    @Bindable var app: AppSession
    @State private var language: String
    @State private var passcode = ""
    @State private var strokes: [[SignaturePoint]] = []
    @State private var busy = false
    @State private var verification: PatientVerification?
    @State private var outcome: VerificationOutcome?
    @State private var error: String?
    @State private var lastActivity = Date()
    @StateObject private var speech = SpeechController()
    @State private var consulting = false
    @State private var canConsult = false
    @Environment(\.scenePhase) private var scenePhase
    public init(record: ReferralRecord, app: AppSession, verification: PatientVerification? = nil) {
        self.record = record; self.app = app; _language = State(initialValue: record.language)
        let matchesRecord = verification?.referralID == record.id && verification?.commitmentHash == record.commitmentHash
        _verification = State(initialValue: matchesRecord ? verification : nil)
    }
    private func t(_ key: String) -> String { Copy.text(key, language) }
    private var walletState: WalletState { app.wallet.first(where: { $0.id == record.id })?.state ?? .available }
    private var isUsed: Bool { [.spent, .provisionalSpend, .conflict].contains(walletState) }
    public var body: some View {
        Form {
            Section("Referral") {
                Text(record.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text(record.clinicalDescription)
                LabeledContent("State", value: walletState.rawValue)
                LabeledContent("Priority", value: "\(record.riskBand.rawValue) · \(record.riskScore)/100 (demo)")
                if record.letterScan.present { Text(record.letterScan.extractedText ?? "Letter noted; no readable text.") }
                if record.lesionPhoto.present { Text(record.lesionPhoto.assessment ?? "Skin concern noted. No medical image model available.") }
            }
            if let verification {
                Section("Patient") {
                    Label("PATIENT VERIFIED", systemImage: "checkmark.seal.fill")
                        .font(.title2.weight(.bold)).foregroundStyle(Color.green)
                    Text("Signature and four-digit code matched at \(verification.verifiedAt.formatted(date: .omitted, time: .shortened)). This confirms the patient for this visit.")
                }
                Section("Consultation") {
                    Button { consulting = true } label: {
                        Label("Start consultation with notes", systemImage: "waveform.and.mic")
                    }.buttonStyle(.borderedProminent).tint(EdgeCareStyle.mulberry).frame(minHeight: 48)
                        .disabled(!canConsult)
                    Text(consultationHint).font(.footnote).foregroundStyle(.secondary)
                }
                if isUsed {
                    Section {
                        Label("Referral already marked used", systemImage: "lock.fill").font(.headline)
                        Text("This referral's single use has already been consumed. You can still verify this patient above for a new visit.")
                    }
                } else {
                    Section {
                        Button { Task { await markUsed(verification) } } label: {
                            if busy { ProgressView() } else { Label("Mark referral as used", systemImage: "checkmark.shield") }
                        }.buttonStyle(.edgeCarePrimary)
                            .disabled(busy || app.session == nil)
                        Text("Verification alone does not use the referral. Marking it used consumes its single use in the shared registry.").font(.footnote).foregroundStyle(.secondary)
                        if let error { Text(error).foregroundStyle(.red) }
                    }
                }
                Section { Button("Verify patient again") { resetVerification() }.disabled(busy) }
            } else {
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
                        if busy { ProgressView() } else { Label("Verify patient", systemImage: "person.badge.shield.checkmark") }
                    }.buttonStyle(.edgeCarePrimary)
                        .disabled(busy || passcode.count != 4 || (strokes.flatMap { $0 }.count < 4 && !isTestingBypass) || app.session == nil)
                    Text("Verification checks the signature and code on this device. It does not mark the referral as used.").font(.footnote).foregroundStyle(.secondary)
                    if isUsed { Text("This referral is already marked used. You can still verify the patient to log a new visit.").font(.footnote).foregroundStyle(.orange) }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section("Synthetic demo") {
                    Text("Only for synthetic demo referrals enrolled with the sample. Code: 1234.").font(.caption)
                    Button("Use sample signature + 1234") { strokes = DemoData.signatureStrokes(); passcode = DemoData.passcode }
                }
            }
            if let outcome {
                Section {
                    let conflict = walletState == .conflict
                    let provisional = outcome.settlement == .provisional && walletState != .spent
                    Label(conflict ? "CONFLICT · shared registry rejected this use" : provisional ? "PROVISIONAL · awaiting registry" : outcome.settlement == .localDemo ? "MARKED USED · local demo only" : "MARKED USED · shared demo registry", systemImage: conflict ? "exclamationmark.octagon" : provisional ? "clock.badge.exclamationmark" : "checkmark.seal.fill")
                        .font(.title2.weight(.bold)).foregroundStyle(conflict ? Color.red : provisional ? Color.orange : Color.green)
                    Text(conflict ? "Another use was accepted first. This provisional use is not confirmed. Review the referral with the clinician." : !provisional && outcome.settlement == .provisional ? "The shared demo registry has now confirmed this use." : outcome.message)
                    if provisional { Text("Offline results do not guarantee single use across devices. First accepted spend wins; sync before treating the registry state as settled.") }
                    Button("Sync and refresh") { Task { await app.sync() } }.disabled(app.busy)
                    if let message = app.message { Text(message).font(.footnote) }
                }
            }
        }
        .edgeCareListBackground()
        .navigationTitle("Verify referral")
        .onChange(of: passcode) { _, _ in lastActivity = Date() }
        .onChange(of: strokes) { _, _ in lastActivity = Date() }
        // While a consultation is open, the verified state underneath must survive: the cover
        // triggers onDisappear and backgrounding is handled by the consultation itself.
        .onChange(of: scenePhase) { _, phase in if phase != .active, !consulting { resetVerification() } }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            if Date().timeIntervalSince(lastActivity) > 120 { clearSecrets() }
        }
        .onDisappear { if !consulting { clearSecrets(); resetVerification() } }
        .task(id: app.simulateOffline) { await refreshConsultAvailability() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in Task { await refreshConsultAvailability() } }
        #if os(iOS)
        .fullScreenCover(isPresented: $consulting, onDismiss: { lastActivity = Date() }) {
            if let session = app.session { ConsultationView(record: record, session: session) }
        }
        #else
        .sheet(isPresented: $consulting) {
            if let session = app.session { ConsultationView(record: record, session: session) }
        }
        #endif
    }
    private var consultationHint: String {
        if !app.connected { return "Live translation needs connected mode. Local demo mode never contacts translation services." }
        if !canConsult { return "Live translation needs a connection. The visit can continue without it." }
        return "Live transcription and two-way translation (ElevenLabs). A summary is written from the transcript, and you and the patient both confirm it before it is saved to the record. No audio is stored."
    }
    private func refreshConsultAvailability() async {
        guard let session = app.session else { canConsult = false; return }
        canConsult = await session.canConsult
    }
    private var isTestingBypass: Bool {
        #if DEBUG
        return passcode == NativeSession.testingBypassPasscode
        #else
        return false
        #endif
    }
    private func clearSecrets() { passcode = ""; strokes = []; speech.stop() }
    private func resetVerification() { verification = nil; outcome = nil; error = nil; clearSecrets() }
    private func verify() async {
        guard let session = app.session else { return }
        busy = true; error = nil; outcome = nil
        let submittedPIN = passcode, submittedStrokes = strokes
        clearSecrets()
        defer { busy = false }
        do { verification = try await session.verify(record: record, passcode: submittedPIN, strokes: submittedStrokes) }
        catch { self.error = t("error") + " (\(error))" }
    }
    private func markUsed(_ verification: PatientVerification) async {
        guard let session = app.session else { return }
        busy = true; error = nil
        defer { busy = false }
        do { outcome = try await session.markUsed(record: record, verification: verification); await app.refresh() }
        catch { self.error = t("error") + " (\(error))" }
    }
}
