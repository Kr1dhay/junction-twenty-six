import SwiftUI
import EdgeCareCore
@MainActor @Observable public final class IntakeViewModel {
    public var language = "en"
    public var concern = ""
    public var guidance: String?
    public var busy = false
    private let triage: any TriageEngine
    public init(triage: any TriageEngine = OnDeviceTriageEngine()) { self.triage = triage }
    public func continueFlow() async {
        busy = true; defer { busy = false }
        do { guidance = try await triage.guidance(for: concern, language: language).message }
        catch { guidance = "Guidance is unavailable. Please try again." }
    }
    public func reset() { concern = ""; guidance = nil }
}
public struct IntakeView: View {
    private let title: String
    @Bindable private var model: IntakeViewModel
    public init(title: String, model: IntakeViewModel) { self.title = title; self.model = model }
    public var body: some View {
        Form {
            Section {
                Label("Anonymous by default", systemImage: "person.crop.circle.badge.checkmark")
                Text("No account, name, email or phone number.")
                Text("Local demo · brand placeholder").font(.caption)
            }
            Section("Choose your language") {
                Picker("Language", selection: $model.language) {
                    Text("English").tag("en"); Text("Suomi").tag("fi"); Text("Soomaali").tag("so")
                    Text("العربية").tag("ar"); Text("Русский").tag("ru")
                }
                Text("Translated conversations and on-device speech are pending.").font(.caption)
            }
            Section("What is worrying you?") {
                TextField("Describe your concern", text: $model.concern, axis: .vertical).lineLimit(4...8)
                Button("Continue") { Task { await model.continueFlow() } }
                    .disabled(model.concern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
            }
            if let guidance = model.guidance { Section("Next step") { Text(guidance) } }
            Section("Referral enrollment · next slice") {
                Text("Signature capture, passcode confirmation and referral sealing will connect here.")
                Text("There is no passcode reset. If you forget your code, you lose access to the referral.")
            }
            Button("End session", role: .destructive) { model.reset() }
        }.navigationTitle(title)
    }
}
