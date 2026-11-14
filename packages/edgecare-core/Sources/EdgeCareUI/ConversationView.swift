import SwiftUI
import EdgeCareCore

struct ConversationView: View {
    @Bindable var model: IntakeViewModel
    @Bindable var app: AppSession
    @StateObject private var conversation = ConversationController()
    @State private var typedTurn = ""
    @Environment(\.scenePhase) private var scenePhase
    private func t(_ key: String) -> String { Copy.text(key, model.language) }
    private var enabled: Bool { model.voiceConsent && app.connected && !app.simulateOffline && app.session != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("voiceDescription"))
            Text(t("cloudDisclosure")).font(.subheadline).foregroundStyle(.secondary)
            Toggle(t("cloudConsent"), isOn: $model.voiceConsent)
            if !app.connected || app.simulateOffline {
                Label(t("voiceUnavailable"), systemImage: "wifi.slash")
            } else {
                Label(t(conversation.statusKey), systemImage: conversation.phase == .listening ? "mic.fill" : "waveform")
                    .font(.subheadline.weight(.medium)).accessibilityAddTraits(.updatesFrequently)
                if conversation.active {
                    Button { conversation.stop() } label: { Label(t("pauseConversation"), systemImage: "pause.circle.fill") }
                        .buttonStyle(.borderedProminent).tint(EdgeCareStyle.mulberry)
                } else {
                    Button { conversation.start(model: model, app: app) } label: {
                        Label(t(model.voiceIntakeComplete ? "updateConversation" : "startConversation"), systemImage: "mic.circle.fill")
                    }.buttonStyle(.borderedProminent).tint(EdgeCareStyle.mulberry).disabled(!enabled)
                }
                TextField(t("turnHint"), text: $typedTurn, axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder)
                    .disabled(conversation.active)
                Button(t("sendText")) {
                    let text = typedTurn.trimmingCharacters(in: .whitespacesAndNewlines)
                    conversation.send(text: text, model: model, app: app)
                }.buttonStyle(.bordered)
                    .disabled(!enabled || conversation.active || typedTurn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if conversation.replyAudio != nil {
                    Button { conversation.replay(model: model) } label: { Label(t("replay"), systemImage: "play.circle") }
                        .frame(minHeight: 48).disabled(!enabled || conversation.active)
                }
                ForEach(Array(model.voiceHistory.enumerated()), id: \.offset) { _, turn in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(turn.role == "assistant" ? "Edge-Care" : t("you")).font(.caption.weight(.semibold)).foregroundStyle(EdgeCareStyle.mulberry)
                        Text(turn.text).textSelection(.enabled)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if conversation.phase == .processing { ProgressView(t("saving")) }
            if let key = conversation.noticeKey { Text(t(key)).foregroundStyle(.secondary) }
            if conversation.textOnly { Text(t("textOnly")).font(.footnote).foregroundStyle(.secondary) }
            if !model.voiceHistory.isEmpty {
                Text(t("profileReview")).font(.headline)
                Text(t("englishProfile")).font(.footnote).foregroundStyle(.secondary)
                LabeledContent(t("profileConcern")) { Text(model.clinicalProfile.concernEnglish).textSelection(.enabled) }
                LabeledContent(t("profileSymptoms")) { Text(model.clinicalProfile.symptomsEnglish.joined(separator: ", ")).textSelection(.enabled) }
                LabeledContent(t("profileDuration")) { Text(model.clinicalProfile.durationEnglish).textSelection(.enabled) }
                LabeledContent(t("profileContext")) { Text(model.clinicalProfile.additionalContextEnglish).textSelection(.enabled) }
                Text(t(model.voiceIntakeComplete ? "conversationComplete" : "profileUpdateHint")).font(.footnote)
            }
            Button(t("useForm")) { conversation.stop(); model.inputMode = "form" }.frame(minHeight: 48)
        }
        .onChange(of: model.voiceConsent) { _, consent in if !consent { conversation.stop(clearReply: true) } }
        .onChange(of: app.simulateOffline) { _, offline in if offline { conversation.stop() } }
        .onChange(of: model.voiceHistory.count) { _, _ in typedTurn = "" }
        .onChange(of: scenePhase) { _, phase in if phase == .background { conversation.stop(clearReply: true) } }
        .onDisappear { conversation.stop(clearReply: true) }
    }
}

struct StructuredConcernForm: View {
    @Bindable var model: IntakeViewModel
    private func t(_ key: String) -> String { Copy.text(key, model.language) }
    static let englishSymptoms = ["skin_change": "New or changing skin lesion", "lump": "New lump or swelling", "unexplained_bleeding": "Unexplained bleeding", "persistent_cough": "Persistent cough", "screening_letter": "Help understanding a screening letter", "other_concern": "Other health concern"]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("symptomQuestion")).font(.headline)
            ForEach(["skin_change", "lump", "unexplained_bleeding", "persistent_cough", "screening_letter", "other_concern"], id: \.self) { symptom in
                Toggle(t(symptom), isOn: Binding(get: { model.selectedSymptoms.contains(symptom) }, set: { selected in
                    if selected { model.selectedSymptoms.insert(symptom) } else { model.selectedSymptoms.remove(symptom) }
                    updateProfile()
                })).frame(minHeight: 44)
            }
            Picker(t("profileDuration"), selection: $model.duration) {
                if model.isUpdatingReferral { Text(model.clinicalProfile.durationEnglish).tag("keep_existing") }
                Text(t("unsure")).tag("unknown")
                Text(t("shortDuration")).tag("less_than_three_weeks")
                Text(t("longDuration")).tag("three_weeks_or_longer")
            }.pickerStyle(.menu).onChange(of: model.duration) { _, _ in updateProfile() }
            Picker(t("severity"), selection: $model.severity) {
                Text(t("unsure")).tag("unknown")
                Text(t("mild")).tag("mild")
                Text(t("moderate")).tag("moderate")
                Text(t("severe")).tag("severe")
            }.pickerStyle(.menu).onChange(of: model.severity) { _, _ in updateProfile() }
            TextField(t("optionalNotes"), text: $model.concern, axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder)
            Text(t("formProfileHint")).font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func updateProfile() {
        let symptoms = model.selectedSymptoms.sorted().compactMap { Self.englishSymptoms[$0] }
        let duration = model.duration == "keep_existing" ? model.clinicalProfile.durationEnglish : ["unknown": "Not sure", "less_than_three_weeks": "Less than three weeks", "three_weeks_or_longer": "Three weeks or longer"][model.duration] ?? "Not sure"
        model.clinicalProfile = ClinicalProfile(concernEnglish: symptoms.joined(separator: "; "), symptomsEnglish: symptoms, durationEnglish: duration, additionalContextEnglish: "Reported severity: \(model.severity). Structured, patient-selected intake; clinician review required.")
        model.lastActivity = Date()
    }
}
