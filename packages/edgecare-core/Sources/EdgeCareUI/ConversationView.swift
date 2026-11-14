import SwiftUI
import EdgeCareCore

struct ConversationView: View {
    @Bindable var model: IntakeViewModel
    @Bindable var app: AppSession
    @Binding var showingConversation: Bool
    @StateObject private var conversation = ConversationController()
    @State private var typedTurn = ""
    @State private var didShowReview = false
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
            Text(t("voiceReadyTitle")).font(.title2.bold()).foregroundStyle(EdgeCareStyle.graphite)
            VStack(alignment: .leading, spacing: 12) {
                Text(t("cloudDisclosure")).font(.subheadline).foregroundStyle(.secondary)
                Toggle(t("cloudConsent"), isOn: $model.voiceConsent)
            }.edgeCareCard(padding: 16)
            if !app.connected || app.simulateOffline {
                Label(t("voiceUnavailable"), systemImage: "wifi.slash")
            } else {
                controls
                DisclosureGroup(t("aboutVoice")) {
                    Text(t("voiceDescription")).font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
                }
                textComposer
            }
            if let key = conversation.noticeKey {
                Label(t(key), systemImage: "exclamationmark.bubble")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.voiceHistory.isEmpty {
                DisclosureGroup(t("conversation")) { transcript }
            }
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
        .onDisappear { if !showingConversation { conversation.stop(clearReply: true) } }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingConversation, onDismiss: { conversation.stop() }) { conversationScreen }
        #else
        .sheet(isPresented: $showingConversation, onDismiss: { conversation.stop() }) { conversationScreen }
        #endif
        .onAppear {
            #if DEBUG
            if reviewPhase != nil && !didShowReview {
                didShowReview = true
                showingConversation = true
            }
            #endif
        }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            Button {
                showingConversation = true
                conversation.start(model: model, app: app)
            } label: {
                VStack(spacing: 16) {
                    VoiceMicrophone(symbol: "mic.fill", size: 184, active: true)
                    Text(t(model.voiceIntakeComplete ? "updateConversation" : "startConversation")).font(.title3.bold())
                }.frame(maxWidth: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(EdgeCareStyle.accent).disabled(!enabled)
            .opacity(enabled ? 1 : 0.55)
            Text(t("voiceReadyHint")).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(.vertical, 12)
    }

    // Screenshot fixtures only render the presentation. They never grant consent,
    // create credentials, start capture, or send speech.
    private var reviewPhase: ConversationController.Phase? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["EDGECARE_VOICE_REVIEW_PHASE"] {
        case "connecting": .connecting
        case "listening": .listening
        case "processing": .processing
        case "speaking": .speaking
        case "settling": .settling
        default: nil
        }
        #else
        nil
        #endif
    }
    private var conversationScreen: some View {
        ConversationStage(
            language: model.language, phase: reviewPhase ?? conversation.phase,
            noticeKey: conversation.noticeKey, history: model.voiceHistory,
            userText: conversation.liveUserText,
            replyText: reviewPhase == .speaking ? Copy.text("concernTitle", model.language) : conversation.liveReplyText,
            controlsEnabled: reviewPhase == nil && enabled,
            canContinue: reviewPhase == nil && hasProfile,
            onBack: { conversation.stop(); showingConversation = false; model.lastActivity = Date() },
            onMicrophone: {
                if conversation.phase == .speaking { conversation.interrupt() }
                else if conversation.active { conversation.stop() }
                else { conversation.start(model: model, app: app) }
            },
            onPause: { conversation.stop() },
            onContinue: { conversation.stop(); showingConversation = false; model.beginSafetyQuestions() }
        )
        .environment(\.layoutDirection, model.language.lowercased().hasPrefix("ar") ? .rightToLeft : .leftToRight)
        .onChange(of: model.voiceConsent) { _, allowed in if !allowed { conversation.stop(clearReply: true) } }
        .onChange(of: app.simulateOffline) { _, offline in if offline { conversation.stop() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { conversation.stop(clearReply: true) } }
        .onDisappear { conversation.stop() }
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

struct VoiceMicrophone: View {
    let symbol: String
    let size: CGFloat
    let active: Bool
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.34, weight: .medium))
            .foregroundStyle(active ? Color.white : EdgeCareStyle.accent)
            .frame(width: size, height: size)
            .background(active ? EdgeCareStyle.mulberry : EdgeCareStyle.blush, in: Circle())
            .overlay(Circle().strokeBorder(EdgeCareStyle.accent.opacity(0.15), lineWidth: 2))
            .padding(12)
            .background(EdgeCareStyle.accent.opacity(0.06), in: Circle())
    }
}

/// Full-screen presentation is independent of audio/network ownership.
struct ConversationStage: View {
    let language: String
    let phase: ConversationController.Phase
    let noticeKey: String?
    let history: [VoiceConversationTurn]
    let userText: String
    let replyText: String
    let controlsEnabled: Bool
    let canContinue: Bool
    let onBack: () -> Void
    let onMicrophone: () -> Void
    let onPause: () -> Void
    let onContinue: () -> Void
    private func t(_ key: String) -> String { Copy.text(key, language) }
    private var busy: Bool { phase == .connecting || phase == .processing || phase == .settling }
    private var dialogue: [VoiceConversationTurn] {
        var turns = Array(history.suffix(2))
        if !userText.isEmpty { turns.append(.init(role: "user", text: userText)) }
        if !replyText.isEmpty { turns.append(.init(role: "assistant", text: replyText)) }
        return Array(turns.suffix(3))
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Button(action: onBack) { Label(t("back"), systemImage: "chevron.backward").padding(.vertical, 12) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("voiceBack")
                    Spacer()
                    EdgeCareWordmark(size: 18)
                }.font(.body.weight(.semibold)).foregroundStyle(EdgeCareStyle.accent).padding(.horizontal, 24)
                Divider().overlay(EdgeCareStyle.hairline)
                ScrollView {
                    VStack(spacing: 16) {
                        Spacer(minLength: 8)
                        Text(t(phase.screenTitleKey))
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(EdgeCareStyle.graphite)
                            .multilineTextAlignment(.center).accessibilityAddTraits([.isHeader, .updatesFrequently])
                            .accessibilityIdentifier("voiceStageTitle")
                        if busy {
                            ZStack {
                                VoiceMicrophone(symbol: phase == .connecting ? "wifi" : phase == .settling ? "mic.slash.fill" : "ellipsis", size: 192, active: false)
                                ProgressView().controlSize(.large).offset(y: 62)
                            }.accessibilityElement(children: .ignore).accessibilityLabel(t(phase.screenTitleKey))
                        } else {
                            Button(action: onMicrophone) {
                                VoiceMicrophone(symbol: "mic.fill", size: 192,
                                                active: phase == .listening || phase == .speaking)
                            }.buttonStyle(.plain).disabled(!controlsEnabled)
                                .accessibilityIdentifier("voiceMicrophone")
                                .accessibilityLabel(t(phase.microphoneActionKey))
                        }
                        Text(t(phase.screenHintKey)).font(phase == .speaking ? .title3.bold() : .title3)
                            .foregroundStyle(phase == .speaking ? EdgeCareStyle.accent : .secondary)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        if let noticeKey {
                            Label(t(noticeKey), systemImage: "exclamationmark.bubble")
                                .font(.subheadline).foregroundStyle(EdgeCareStyle.accent)
                        }
                        if !dialogue.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(t("latestDialogue")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ScrollViewReader { proxy in
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 12) {
                                            ForEach(Array(dialogue.enumerated()), id: \.offset) { _, turn in
                                                VStack(alignment: .leading, spacing: 6) {
                                                    Text(turn.role == "user" ? t("you") : "Edi").font(.caption.bold()).foregroundStyle(EdgeCareStyle.accent)
                                                    Text(turn.text).font(.title3).foregroundStyle(EdgeCareStyle.graphite)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                }.frame(maxWidth: .infinity, alignment: .leading)
                                                    .padding(18).background(turn.role == "user" ? EdgeCareStyle.blush : EdgeCareStyle.card,
                                                                           in: RoundedRectangle(cornerRadius: 20))
                                                    .accessibilityElement(children: .combine)
                                            }
                                            Color.clear.frame(height: 1).id("latest")
                                        }
                                    }
                                    .defaultScrollAnchor(.bottom)
                                    .onChange(of: dialogue.map(\.text)) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
                                }
                                .frame(height: min(260, max(160, geometry.size.height * 0.26)))
                            }.frame(maxWidth: 760)
                        }
                        Spacer(minLength: 8)
                        if phase == .listening || phase == .speaking || busy {
                            Button(t("pauseConversation"), action: onPause).buttonStyle(.edgeCareSecondary).disabled(!controlsEnabled)
                        }
                        if canContinue && (phase == .paused || phase == .complete) {
                            Button(t("next"), action: onContinue).buttonStyle(.edgeCarePrimary)
                        }
                    }
                    .padding(24).frame(maxWidth: 900)
                    .frame(minHeight: max(0, geometry.size.height - 65))
                    .frame(maxWidth: .infinity)
                }
            }.background(EdgeCareStyle.canvas.ignoresSafeArea())
        }.interactiveDismissDisabled()
    }
}

extension ConversationController.Phase {
    var screenTitleKey: String {
        switch self {
        case .ready: "voiceReadyTitle"
        case .connecting: "voiceConnectingTitle"
        case .listening: "voiceListeningTitle"
        case .processing: "voiceProcessingTitle"
        case .speaking: "voiceSpeakingTitle"
        case .settling: "voiceSettlingTitle"
        case .paused: "conversationPaused"
        case .complete: "conversationComplete"
        }
    }
    var screenHintKey: String {
        switch self {
        case .connecting: "voiceConnectingHint"
        case .listening: "conversationListening"
        case .processing: "voiceProcessingHint"
        case .speaking: "voiceSpeakingHint"
        case .settling: "voiceSettlingHint"
        default: "voiceReadyHint"
        }
    }
    var microphoneActionKey: String {
        switch self {
        case .speaking: "interruptReply"
        case .listening, .processing, .connecting, .settling: "pauseConversation"
        default: "startConversation"
        }
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
