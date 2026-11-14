import SwiftUI
import EdgeCareCore

struct ConversationView: View {
    @Bindable var model: IntakeViewModel
    @Bindable var app: AppSession
    @StateObject private var conversation = ConversationController()
    @State private var typedTurn = ""
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var transcriptHeight = 320
    private func t(_ key: String) -> String { Copy.text(key, model.language) }
    private var enabled: Bool { model.voiceConsent && app.connected && !app.simulateOffline && app.session != nil }
    private var hasProfile: Bool {
        !model.clinicalProfile.concernEnglish.isEmpty || !model.clinicalProfile.symptomsEnglish.isEmpty ||
        !model.clinicalProfile.durationEnglish.isEmpty || !model.clinicalProfile.additionalContextEnglish.isEmpty
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(t("voiceDescription"))
            VStack(alignment: .leading, spacing: 12) {
                Text(t("cloudDisclosure")).font(.subheadline).foregroundStyle(.secondary)
                Toggle(t("cloudConsent"), isOn: $model.voiceConsent)
            }.edgeCareCard(padding: 16)
            if !app.connected || app.simulateOffline {
                Label(t("voiceUnavailable"), systemImage: "wifi.slash")
            } else {
                controls
                textComposer
            }
            if let key = conversation.noticeKey {
                Label(t(key), systemImage: "exclamationmark.bubble")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.voiceHistory.isEmpty { transcript }
            if conversation.replyAudio != nil {
                Button { conversation.replay(model: model) } label: { Label(t("replay"), systemImage: "play.circle") }
                    .buttonStyle(.edgeCareSecondary).disabled(!enabled || conversation.active)
            }
            if hasProfile { profile }
            Button(t("useForm")) { conversation.stop(); model.inputMode = "form" }.buttonStyle(.edgeCareSecondary)
        }
        .onChange(of: model.voiceConsent) { _, consent in if !consent { conversation.stop(clearReply: true) } }
        .onChange(of: app.simulateOffline) { _, offline in if offline { conversation.stop() } }
        .onChange(of: model.voiceHistory.count) { _, _ in typedTurn = "" }
        .onChange(of: scenePhase) { _, phase in if phase == .background { conversation.stop(clearReply: true) } }
        .onDisappear { conversation.stop(clearReply: true) }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                EdiView(pose: .listening, animated: false).frame(width: 52, height: 54)
                VStack(alignment: .leading, spacing: 8) {
                    Label(t(conversation.statusKey), systemImage: conversation.phase == .listening ? "mic.fill" : "waveform")
                        .font(.headline).accessibilityAddTraits(.updatesFrequently)
                    if conversation.phase == .connecting || conversation.phase == .processing {
                        ProgressView().controlSize(.small).accessibilityLabel(t(conversation.statusKey))
                    }
                }
            }
            if conversation.phase == .speaking {
                Button { conversation.interrupt() } label: { Label(t("interruptReply"), systemImage: "mic.fill") }
                    .buttonStyle(.edgeCarePrimary)
                pauseButton
            } else if conversation.active {
                pauseButton
            } else {
                Button { conversation.start(model: model, app: app) } label: {
                    Label(t(model.voiceIntakeComplete ? "updateConversation" : "startConversation"), systemImage: "mic.circle.fill")
                }.buttonStyle(.edgeCarePrimary).disabled(!enabled)
            }
        }.edgeCareCard(padding: 16)
    }

    private var pauseButton: some View {
        Button { conversation.stop() } label: { Label(t("pauseConversation"), systemImage: "pause.circle") }
            .buttonStyle(EdgeCareSecondaryButtonStyle(fullWidth: true))
    }

    private var textComposer: some View {
        DisclosureGroup(t("useTextInstead")) {
            VStack(alignment: .leading, spacing: 12) {
                TextField(t("turnHint"), text: $typedTurn, axis: .vertical)
                    .lineLimit(2...6).textFieldStyle(.roundedBorder).accessibilityLabel(t("turnHint"))
                    .disabled(conversation.active)
                Button(t("sendText")) {
                    conversation.send(text: typedTurn.trimmingCharacters(in: .whitespacesAndNewlines), model: model, app: app)
                }.buttonStyle(.edgeCareSecondary)
                    .disabled(!enabled || conversation.active || typedTurn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.top, 12)
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("conversation")).font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(model.voiceHistory.enumerated()), id: \.offset) { index, turn in
                            message(turn).id(index)
                        }
                    }.padding(4)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.voiceHistory.count) { _, count in
                    guard count > 0 else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }.frame(height: min(transcriptHeight, 480))
        }
    }

    private func message(_ turn: VoiceConversationTurn) -> some View {
        let fromGuide = turn.role == "assistant"
        return HStack(alignment: .top, spacing: 10) {
            if !fromGuide { Spacer(minLength: 24) }
            if fromGuide { EdiView(pose: .listening, animated: false).frame(width: 30, height: 31) }
            VStack(alignment: .leading, spacing: 6) {
                Text(fromGuide ? "Edge-Care" : t("you")).font(.caption.weight(.semibold)).foregroundStyle(EdgeCareStyle.accent)
                Text(turn.text).foregroundStyle(EdgeCareStyle.graphite).textSelection(.enabled)
            }
            .padding(14)
            .background(fromGuide ? EdgeCareStyle.card : EdgeCareStyle.blush, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(EdgeCareStyle.hairline, lineWidth: fromGuide ? 1 : 0))
            .accessibilityElement(children: .combine)
            if fromGuide { Spacer(minLength: 24) }
        }.frame(maxWidth: .infinity, alignment: fromGuide ? .leading : .trailing)
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("profileReview")).font(.headline)
            Text(t("englishProfile")).font(.footnote).foregroundStyle(.secondary)
            profileField("profileConcern", model.clinicalProfile.concernEnglish)
            profileField("profileSymptoms", model.clinicalProfile.symptomsEnglish.joined(separator: ", "))
            profileField("profileDuration", model.clinicalProfile.durationEnglish)
            profileField("profileContext", model.clinicalProfile.additionalContextEnglish)
            Text(t(model.voiceIntakeComplete ? "conversationComplete" : "profileUpdateHint")).font(.footnote).foregroundStyle(.secondary)
        }.edgeCareCard(padding: 16)
    }

    private func profileField(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t(key)).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? t("notYetProvided") : value).textSelection(.enabled)
        }.accessibilityElement(children: .combine)
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
                })).toggleStyle(.edgeCareCheckRow)
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
