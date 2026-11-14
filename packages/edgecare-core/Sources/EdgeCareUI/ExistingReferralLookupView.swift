import SwiftUI
import EdgeCareCore

struct ExistingReferralLookupView: View {
    @Bindable var model: IntakeViewModel
    @Bindable var app: AppSession
    @State private var passcode = ""
    @State private var strokes: [[SignaturePoint]] = []
    @State private var candidates: [ReferralEditSession] = []
    @State private var busy = false
    @State private var errorKey: String?
    @State private var task: Task<Void, Never>?
    @State private var generation = 0
    @State private var lastActivity = Date()
    @Environment(\.scenePhase) private var scenePhase
    private func t(_ key: String) -> String { Copy.text(key, model.language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(t("updateExisting")).font(.largeTitle.weight(.semibold))
            Text(t("verifyToUpdate"))
            PINField(title: t("enterPin"), value: $passcode).disabled(busy)
            SignaturePad(strokes: $strokes, language: model.language).id(generation).disabled(busy)
            Button(t("findExisting")) { find() }.buttonStyle(.borderedProminent).tint(EdgeCareStyle.mulberry)
                .disabled(busy || app.session == nil || passcode.count != 4 || strokes.flatMap { $0 }.count < 4)
            if busy { ProgressView(t("saving")) }
            if let errorKey { Text(t(errorKey)).foregroundStyle(.secondary) }
            if !candidates.isEmpty {
                Text(t("chooseExisting")).font(.headline)
                ForEach(candidates, id: \.original.id) { candidate in
                    Button { model.loadExistingReferral(candidate) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(candidate.original.id).font(.caption.monospaced())
                            Text(candidate.clinicalProfile.clinicianSummary).lineLimit(3)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.buttonStyle(.bordered)
                }
            }
            Button(t("cancel")) { cancel(); model.reset() }.frame(minHeight: 48)
        }
        .onChange(of: passcode) { _, value in lastActivity = Date(); model.lastActivity = Date(); if !value.isEmpty { candidates = [] } }
        .onChange(of: strokes) { _, value in lastActivity = Date(); model.lastActivity = Date(); if !value.isEmpty { candidates = [] } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancel() } }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if Date().timeIntervalSince(lastActivity) >= 120 { cancel() }
        }
        .onDisappear { cancel() }
    }
    private func cancel() {
        generation += 1; task?.cancel(); task = nil
        passcode = ""; strokes = []; candidates = []; busy = false
    }
    private func find() {
        guard let session = app.session else { return }
        let pin = passcode, signature = strokes
        cancel(); busy = true; errorKey = nil; lastActivity = Date(); model.lastActivity = Date()
        let current = generation
        task = Task {
            defer { if generation == current { busy = false; task = nil } }
            do {
                let result = try await session.findReferrals(passcode: pin, strokes: signature)
                guard !Task.isCancelled, current == generation, scenePhase == .active else { return }
                let unlocked = result.matches.compactMap { try? EnrollmentService().unlock(record: $0.record, passcode: pin, strokes: signature) }
                if unlocked.count == 1, let match = unlocked.first { model.loadExistingReferral(match) }
                else { candidates = unlocked; if unlocked.isEmpty { errorKey = result.searchedLocalOnly ? "existingNotFoundLocal" : "existingNotFound" } }
            } catch {
                guard !Task.isCancelled, current == generation else { return }
                errorKey = "existingLookupFailed"
            }
        }
    }
}
