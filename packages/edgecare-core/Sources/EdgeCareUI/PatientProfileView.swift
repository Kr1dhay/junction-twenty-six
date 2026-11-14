import SwiftUI
import EdgeCareCore

/// Patient ownership is verified again on every visit to this screen.
struct PatientProfileView: View {
    @Bindable var app: AppSession
    let language: String
    let onDelete: (String) -> Void
    @State private var passcode = ""
    @State private var strokes: [[SignaturePoint]] = []
    @State private var profiles: [PatientProfileAccess] = []
    @State private var busy = false
    @State private var confirming = false
    @State private var notice: String?
    @State private var generation = 0
    @State private var signedInAt: Date?
    @State private var loginTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    private func t(_ key: String) -> String { Copy.text(key, language) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SessionBanner(connected: app.connected, language: language)
                if profiles.isEmpty {
                    Text(t("profileSignInHint"))
                    ReferralVerificationFields(title: t("enterPin"), passcode: $passcode, strokes: $strokes,
                                               language: language).id(generation).disabled(busy)
                    Button(t("profileSignIn")) { signIn() }
                        .buttonStyle(.edgeCarePrimary)
                        .disabled(busy || app.session == nil || passcode.count != 4 || strokes.flatMap { $0 }.count < 4)
                } else {
                    ForEach(profiles) { profile in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(profile.record.id).font(.caption.monospaced()).textSelection(.enabled)
                            Text(profile.record.patientLanguageSummary)
                            LabeledContent(t("expires"), value: String(profile.record.expiresAt.prefix(10)))
                        }.edgeCareCard()
                    }
                    Text(t(app.connected ? "profileDeleteScope" : "profileDeleteLocalScope")).font(.footnote)
                    Button(role: .destructive) { confirming = true } label: {
                        Label(t("profileDelete"), systemImage: "trash")
                    }.buttonStyle(.edgeCareSecondary).disabled(busy)
                    Button(t("profileSignOut")) { signOut() }.buttonStyle(.edgeCareSecondary).disabled(busy)
                }
                if busy { ProgressView(t("saving")) }
                if let notice { Text(t(notice)).font(.footnote).accessibilityIdentifier("patientProfileNotice") }
            }.padding(24).frame(maxWidth: 720)
        }
        .background(EdgeCareBackground())
        .navigationTitle(t("myProfile"))
        .confirmationDialog(t("profileDeleteConfirm"), isPresented: $confirming, titleVisibility: .visible) {
            Button(t("profileDelete"), role: .destructive) { deleteProfiles() }
            Button(t("cancel"), role: .cancel) {}
        } message: {
            Text(t(app.connected ? "profileDeleteScope" : "profileDeleteLocalScope"))
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { signOut() } }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if !busy, let signedInAt, Date().timeIntervalSince(signedInAt) >= 300 { signOut() }
        }
        .onDisappear { signOut() }
        .environment(\.layoutDirection, language.lowercased().hasPrefix("ar") ? .rightToLeft : .leftToRight)
    }
    private func signOut() {
        generation += 1; loginTask?.cancel(); loginTask = nil
        passcode = ""; strokes = []; profiles = []; signedInAt = nil; confirming = false; notice = nil
        // A confirmed deletion finishes even when this view leaves the foreground.
    }
    private func signIn() {
        guard let session = app.session else { return }
        let code = passcode, signature = strokes
        signOut(); busy = true
        let current = generation
        loginTask = Task {
            defer { busy = false; loginTask = nil }
            do {
                let found = try await session.patientProfiles(passcode: code, strokes: signature)
                guard !Task.isCancelled, generation == current, scenePhase == .active else { return }
                profiles = found; signedInAt = Date()
                if found.isEmpty { notice = "existingNotFound" }
            } catch {
                guard !Task.isCancelled, generation == current else { return }
                notice = "profileSignInFailed"
            }
        }
    }
    private func deleteProfiles() {
        guard let session = app.session, !busy, !profiles.isEmpty else { return }
        let selected = profiles
        confirming = false; busy = true; notice = nil
        let current = generation
        Task {
            defer { busy = false }
            do {
                for profile in selected {
                    try await session.deletePatientProfile(profile)
                    // Always clear the shared UI state, including a completed intake draft.
                    onDelete(profile.id)
                    await app.refreshCachedRecords()
                    if generation == current { profiles.removeAll { $0.id == profile.id } }
                }
                if generation == current { signOut(); notice = "profileDeleted" }
            } catch {
                await app.refreshCachedRecords()
                if generation == current { notice = "profileDeleteFailed" }
            }
        }
    }
}
