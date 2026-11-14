import SwiftUI
import Observation
import Combine
import EdgeCareCore

@MainActor @Observable public final class IntakeViewModel {
    public var language = "en"
    public var concern = ""
    public var inputMode = "form"
    public var selectedSymptoms: Set<String> = []
    public var duration = "unknown"
    public var severity = "unknown"
    public var clinicalProfile = ClinicalProfile()
    public var voiceHistory: [VoiceConversationTurn] = []
    public var voiceConsent = false
    public var voiceIntakeComplete = false
    public var guidance: TriageGuidance?
    public var busy = false
    public var step = 0
    public var safety = SafetyQuestionnaireState(plan: [])
    public var emergencyAdvicePending = false
    public var continuedAfterEmergencyAdvice = false
    public var urgent: String? { aggregateAnswer(.emergency) }
    public var persistent: String? { aggregateAnswer(.persistence) }
    public var requiresEmergencyAdvice: Bool { safety.requiresEmergencyHelp || guidance?.requiresEmergencyHelp == true }
    public var letterText = ""
    public var lesionPresent = false
    public var strokes: [[SignaturePoint]] = []
    public var passcode = ""
    public var confirmation = ""
    public var understood = false
    public var record: ReferralRecord?
    public var appointmentVerification: PatientVerification?
    public var editingReferral: ReferralEditSession?
    public var isUpdatingReferral: Bool { editingReferral != nil }
    public var didUpdateReferral = false
    private var pendingUpdate: ReferralUpdate?
    public var error: String?
    public var languageChosen = false
    public var languageDetected = false
    public var lastActivity = Date()
    private var generation = 0
    private struct SafetyInput: Equatable {
        let profile: ClinicalProfile
        let selectedSymptoms: Set<String>
        let concern: String
    }
    private var safetyInput: SafetyInput?
    public let source: ReferralSource
    private let triage: any TriageEngine
    public init(source: ReferralSource = .patientApp, triage: any TriageEngine = OnDeviceTriageEngine()) { self.source = source; self.triage = triage }
    public func loadExistingReferral(_ session: ReferralEditSession) {
        reset()
        editingReferral = session; clinicalProfile = session.clinicalProfile
        let marker = "\nPatient notes (original language): "
        concern = session.concern.components(separatedBy: marker).last ?? session.concern
        language = session.original.language; languageChosen = true
        letterText = session.letterText ?? ""; lesionPresent = session.original.lesionPhoto.present
        let mapping = ["skin_change": "skin_change", "lump_or_swelling": "lump", "cough": "persistent_cough", "unexplained_bleeding": "unexplained_bleeding", "screening_letter": "screening_letter"]
        selectedSymptoms = Set(session.original.symptoms.compactMap { mapping[$0] })
        if selectedSymptoms.isEmpty { selectedSymptoms = ["other_concern"] }
        duration = "keep_existing"; inputMode = "voice"; voiceIntakeComplete = true
        voiceHistory = [VoiceConversationTurn(role: "assistant", text: Copy.text("existingLoaded", language))]
        step = 1
    }
    public func discardPreparedUpdate() { pendingUpdate = nil }
    public func beginSafetyQuestions() {
        guard !busy else { return }
        let input = SafetyInput(profile: clinicalProfile, selectedSymptoms: selectedSymptoms, concern: concern)
        if safetyInput != input {
            safety.reset(plan: SafetyQuestionnaire.plan(profile: clinicalProfile, selectedSymptoms: selectedSymptoms, originalConcern: concern))
            continuedAfterEmergencyAdvice = false
            safetyInput = input
        }
        emergencyAdvicePending = false; guidance = nil; error = nil
        advanceSafetyStep()
    }
    public func answerSafetyQuestion(_ answer: SafetyAnswer) {
        guard !busy, let question = safety.currentQuestion, !emergencyAdvicePending else { return }
        safety.answer(answer, for: question.id)
        guidance = nil; error = nil; lastActivity = Date()
        if question.category == .emergency && answer == .yes {
            emergencyAdvicePending = true
        } else { advanceSafetyStep() }
    }
    public func continueAfterEmergencyAdvice() {
        guard !busy, emergencyAdvicePending else { return }
        continuedAfterEmergencyAdvice = true; emergencyAdvicePending = false
        advanceSafetyStep()
    }
    public func proceedToReferral() {
        guard !busy, let guidance else { return }
        if guidance.requiresEmergencyHelp {
            continuedAfterEmergencyAdvice = true
            self.guidance = annotated(guidance)
        }
        step = 6
    }
    public func goBack() {
        guard !busy else { return }
        error = nil
        if emergencyAdvicePending {
            emergencyAdvicePending = false
            _ = safety.moveBack(); advanceSafetyStep()
        } else if (2...4).contains(step) {
            if safety.moveBack() { advanceSafetyStep() } else { step = 1 }
        } else { step = max(1, step - 1) }
    }
    private func advanceSafetyStep() {
        if let question = safety.currentQuestion { step = question.category == .emergency ? 2 : 3 }
        else { step = 4 }
        lastActivity = Date()
    }
    private func aggregateAnswer(_ category: SafetyQuestionCategory) -> String? {
        let questions = safety.plan.filter { $0.category == category }
        guard !questions.isEmpty else { return nil }
        let answers = questions.compactMap { safety.answers[$0.id.rawValue] }
        if answers.contains("yes") { return "yes" }
        if answers.count < questions.count || answers.contains("unsure") { return "unsure" }
        return "no"
    }
    public var referralAnswers: [String: String] {
        var answers = safety.portableAnswers
        answers["urgent_now"] = urgent ?? "unsure"
        answers["persistent_or_changing"] = persistent ?? "unsure"
        if continuedAfterEmergencyAdvice { answers["emergency_advice_action"] = "continued_questionnaire_or_referral_after_112_advice" }
        return answers
    }
    private func annotated(_ result: TriageGuidance) -> TriageGuidance {
        let continuation = "Patient chose to continue the referral after emergency advice. Contact with emergency services has not been verified."
        guard continuedAfterEmergencyAdvice, !result.clinicianSummary.contains(continuation) else { return result }
        return TriageGuidance(message: result.message, followUpQuestions: result.followUpQuestions,
            riskBand: result.riskBand, riskScore: result.riskScore, recommendedSpecialty: result.recommendedSpecialty,
            symptoms: result.symptoms, clinicianSummary: result.clinicianSummary + " " + continuation,
            label: result.label, requiresEmergencyHelp: result.requiresEmergencyHelp, sources: result.sources)
    }
    public func continueFlow() async {
        guard !safety.plan.isEmpty, safety.isComplete else { error = Copy.text("error", language); return }
        let currentGeneration = generation
        busy = true; defer { if generation == currentGeneration { busy = false } }
        let structured = "\(clinicalProfile.clinicianSummary)\n\(concern)\n[urgent_now=\(urgent ?? "unsure")]\n[persistent_or_changing=\(persistent ?? "unsure")]" + (letterText.isEmpty ? "" : "\nScreening letter: \(letterText)") + (lesionPresent ? "\nSkin concern photo noted; no image model assessment." : "")
        do {
            let result = try await triage.guidance(for: structured, language: language)
            guard generation == currentGeneration else { return }
            guidance = annotated(result); pendingUpdate = nil; step = 5
        }
        catch { if generation == currentGeneration { self.error = Copy.text("error", language) } }
    }
    public func enroll(using app: AppSession) async {
        guard let session = app.session, let guidance else { error = Copy.text("error", language); return }
        if !isUpdatingReferral {
            guard passcode.count == 4, passcode == confirmation, understood else { error = Copy.text("pinMismatch", language); return }
        }
        let currentGeneration = generation
        busy = true; defer { if generation == currentGeneration { busy = false } }
        do {
            let draft = EnrollmentDraft(source: source, language: language, concern: clinicalProfile.clinicianSummary + "\nPatient notes (original language): " + concern, guidance: guidance, letterText: letterText.isEmpty ? nil : letterText, lesionPresent: lesionPresent, answers: referralAnswers, clinicalProfile: clinicalProfile)
            let sealed: ReferralRecord
            if let editingReferral {
                if pendingUpdate == nil { pendingUpdate = try EnrollmentService().prepareUpdate(session: editingReferral, draft: draft) }
                guard let pendingUpdate else { throw CoreError.invalidConfiguration }
                sealed = try await session.updateReferral(pendingUpdate, authorization: editingReferral)
            } else { sealed = try await session.enroll(draft: draft, strokes: strokes, passcode: passcode, confirmation: confirmation) }
            let bookingProof: PatientVerification?
            if let editingReferral { bookingProof = await session.appointmentVerification(for: editingReferral) }
            else { bookingProof = try? await session.verify(record: sealed, passcode: passcode, strokes: strokes) }
            guard generation == currentGeneration else { return }
            appointmentVerification = bookingProof
            didUpdateReferral = isUpdatingReferral; editingReferral = nil; pendingUpdate = nil
            record = sealed
            passcode = ""; confirmation = ""; strokes = []; step = 7
            await app.refresh()
        } catch {
            if generation == currentGeneration {
                self.error = isUpdatingReferral && (error as? CoreError) == .conflict
                    ? Copy.text("updateConflict", language) : Copy.text("error", language) + " (\(error))"
            }
        }
    }
    public func reset() {
        generation += 1; busy = false
        editingReferral = nil; pendingUpdate = nil; didUpdateReferral = false; appointmentVerification = nil
        inputMode = "form"; selectedSymptoms = []; duration = "unknown"; severity = "unknown"; clinicalProfile = ClinicalProfile(); voiceHistory = []; voiceConsent = false; voiceIntakeComplete = false
        concern = ""; guidance = nil; step = 0; safety.reset(plan: []); safetyInput = nil; emergencyAdvicePending = false; continuedAfterEmergencyAdvice = false; letterText = ""; lesionPresent = false
        strokes = []; passcode = ""; confirmation = ""; understood = false; record = nil; error = nil
        language = "en"; languageChosen = false; languageDetected = false; lastActivity = Date()
    }
}

public struct IntakeView: View {
    private let title: String
    @Bindable private var model: IntakeViewModel
    @Bindable private var app: AppSession
    private let kiosk: Bool
    @StateObject private var speech = SpeechController()
    @State private var voiceScreenPresented = false
    @State private var idleSoon = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    public init(title: String, model: IntakeViewModel, app: AppSession, kiosk: Bool = false) {
        self.title = title; self.model = model; self.app = app; self.kiosk = kiosk
    }
    private func t(_ key: String) -> String { Copy.text(key, model.language) }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if kiosk {
                    languagePicker.frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            SessionBanner(connected: app.connected, language: model.language).fixedSize()
                            Spacer()
                            languagePicker.fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            SessionBanner(connected: app.connected, language: model.language)
                            languagePicker
                        }
                    }
                }
                if model.step > 0 && model.step < 7 && !(model.step == 1 && model.inputMode == "voice") {
                    ProgressView(value: Double(model.step), total: 7).tint(EdgeCareStyle.magenta)
                        .accessibilityLabel("\(model.step) / 7")
                }
                if app.session == nil, let message = app.message { Text(message).foregroundStyle(.red) }
                if model.requiresEmergencyAdvice && model.step >= 2 && model.step != 5 && !model.emergencyAdvicePending {
                    emergencyNotice
                }
                content.disabled(model.busy)
                if let error = model.error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                if model.busy { ProgressView(t("saving")) }
                if model.step > 0 {
                    HStack {
                        if model.step < 7 && model.step > 1 {
                            Button(t("back")) { speech.stop(); model.goBack() }.buttonStyle(.edgeCareSecondary).disabled(model.busy)
                        }
                        Spacer()
                        Button(t("end"), role: .destructive) { reset() }.buttonStyle(.edgeCareSecondary)
                    }
                }
                if kiosk && idleSoon {
                    Text(t("idleSoon")).font(.footnote).accessibilityAddTraits(.updatesFrequently)
                }
            }
            .padding(24).frame(maxWidth: kiosk && model.step == 0 ? 980 : 720).frame(maxWidth: .infinity)
        }
        .background(EdgeCareBackground())
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .environment(\.layoutDirection, model.language.lowercased().hasPrefix("ar") ? .rightToLeft : .leftToRight)
        .onChange(of: model.language) { _, language in model.lastActivity = Date(); speech.stop(); app.language = language }
        .onChange(of: model.concern) { _, text in
            model.discardPreparedUpdate()
            model.lastActivity = Date()
            if !model.languageChosen, !model.languageDetected, let language = detectedLanguage(text) {
                model.language = language; model.languageDetected = true
            }
        }
        .onChange(of: model.step) { _, _ in model.lastActivity = Date(); speech.stop() }
        .onChange(of: model.inputMode) { _, _ in speech.stop() }
        .onChange(of: model.letterText) { _, _ in model.lastActivity = Date(); model.discardPreparedUpdate() }
        .onChange(of: model.clinicalProfile) { _, _ in model.discardPreparedUpdate() }
        .onChange(of: model.lesionPresent) { _, _ in model.discardPreparedUpdate() }
        .onChange(of: model.passcode) { _, _ in model.lastActivity = Date() }
        .onChange(of: model.confirmation) { _, _ in model.lastActivity = Date() }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in model.lastActivity = Date(); idleSoon = false })
        .onReceive(timer) { _ in
            guard kiosk, model.step > 0 else { return }
            let idle = Date().timeIntervalSince(model.lastActivity)
            idleSoon = idle > 150
            if idle >= 180 { reset() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { if kiosk { reset() } else { speech.stop(); model.passcode = ""; model.confirmation = "" } }
        }
        .toolbar {
            ToolbarItem(placement: .principal) { EdgeCareWordmark(size: 18) }
            ToolbarItem {
                Menu {
                    if kiosk { Text(t(app.connected ? "connected" : "local")) }
                    if app.connected { Toggle(t("simulateOffline"), isOn: $app.simulateOffline) }
                    Button(t("sync")) { Task { await app.sync() } }.disabled(app.busy)
                    if kiosk && model.step == 6 && !model.isUpdatingReferral {
                        Divider()
                        Button(t("demoUse")) { useSampleCredentials() }
                    }
                } label: {
                    if kiosk { Image(systemName: "gearshape").accessibilityLabel(t("settings")) }
                    else { Text(t("demoControls")) }
                }
                .accessibilityIdentifier("intakeSettings")
            }
        }
        .onDisappear {
            speech.stop(); model.passcode = ""; model.confirmation = ""
            if !voiceScreenPresented && model.isUpdatingReferral { model.reset() }
        }
    }
    @ViewBuilder private var content: some View {
        switch model.step {
        case -1:
            ExistingReferralLookupView(model: model, app: app)
        case 0:
            if kiosk && !dynamicTypeSize.isAccessibilitySize && horizontalSizeClass != .compact {
                HStack(alignment: .center, spacing: 40) {
                    EdiView(pose: .welcome).frame(maxWidth: 320, maxHeight: 340)
                    welcomeIntro
                }
            } else {
                EdiView(pose: .welcome).frame(width: 112, height: 114)
                welcomeIntro
            }
        case 1:
            if let editing = model.editingReferral {
                Label(t("updatingExisting"), systemImage: "pencil.circle").font(.headline)
                Text(editing.original.id).font(.caption.monospaced()).textSelection(.enabled)
            }
            if model.inputMode != "voice" {
                guideHeading(t("concernTitle"), pose: .listening)
                if !kiosk { Text(t("anonymous")).foregroundStyle(.secondary) }
            }
            Picker(t("inputMode"), selection: $model.inputMode) {
                Text(t("form")).tag("form")
                Text(t("conversation")).tag("voice")
            }.pickerStyle(.segmented)
            if model.inputMode == "voice" {
                ConversationView(model: model, app: app, showingConversation: $voiceScreenPresented)
            } else {
                StructuredConcernForm(model: model, compact: kiosk)
                if model.languageDetected { Text(t("detected")).font(.footnote) }
                speechControls(prompt: t("concernTitle"), input: true)
            }
            primary(t("next")) { model.beginSafetyQuestions() }
                .disabled(model.inputMode == "form" ? model.selectedSymptoms.isEmpty : model.clinicalProfile.concernEnglish.isEmpty)

        case 2, 3:
            if model.emergencyAdvicePending {
                heading(t("emergencyTitle"))
                emergencyNotice
                Text(t("emergencyContinueExplanation"))
                primary(t("continueQuestionnaire")) { model.continueAfterEmergencyAdvice() }
                speechControls(prompt: t("emergencyAdvice"), input: false)
            } else if let question = model.safety.currentQuestion {
                safetyQuestion(question)
            }
        case 4:
            heading(t("evidence"))
            EvidenceCapture(language: model.language, letterText: $model.letterText, lesionPresent: $model.lesionPresent)
            primary(t("next")) { Task { await model.continueFlow() } }.disabled(model.busy)
        case 5:
            guideHeading(t("guidance"), pose: .nextStep)
            if let guidance = model.guidance {
                Text(guidance.message).font(.title3)
                if !kiosk { Text(t("review")).font(.subheadline).foregroundStyle(.secondary) }
                speechControls(prompt: guidance.message, input: false)
                if !kiosk { safetySources }
                if guidance.requiresEmergencyHelp {
                    emergencyNotice
                    Text(t("emergencyContinueExplanation"))
                    primary(t("continueReferral")) { model.proceedToReferral() }
                } else { primary(t(model.isUpdatingReferral ? "reviewUpdate" : "seal")) { model.proceedToReferral() } }
                if kiosk {
                    DisclosureGroup(t("sources")) { safetySources.padding(.top, 8) }
                        .font(.subheadline).accessibilityIdentifier("guidanceSources")
                }
            }
        case 6:
            if model.isUpdatingReferral {
                heading(t("reviewUpdate"))
                Text(t("updateKeepsCredentials"))
                Text(model.clinicalProfile.clinicianSummary).textSelection(.enabled)
                primary(t("saveUpdate")) { Task { await model.enroll(using: app) } }.disabled(model.busy || app.session == nil)
            } else {
                heading(t("seal"))
                Text(t("signature")).font(.headline)
                SignaturePad(strokes: $model.strokes, language: model.language)
                PINField(title: t("pin"), value: $model.passcode)
                PINField(title: t("confirmPin"), value: $model.confirmation)
                Label(t("noReset"), systemImage: "lock.trianglebadge.exclamationmark").font(.body.weight(.medium))
                Toggle(t("understand"), isOn: $model.understood).padding(.vertical, 8)
                speechControls(prompt: t("noReset"), input: false)
                if model.passcode.count == 4 && model.confirmation.count == 4 && model.passcode != model.confirmation {
                    Text(t("pinMismatch")).foregroundStyle(.red)
                }
                primary(t("seal")) { Task { await model.enroll(using: app) } }
                    .disabled(model.busy || model.strokes.flatMap { $0 }.count < 4 || model.passcode.count != 4 || model.passcode != model.confirmation || !model.understood || app.session == nil)
                if !kiosk {
                    DisclosureGroup(t("demoDisclosure")) {
                        Text(t("demoDetail")).font(.caption)
                        Button(t("demoUse")) { useSampleCredentials() }.buttonStyle(.edgeCareSecondary)
                    }.font(.footnote)
                }
            }
        case 7:
            guideHeading(t(model.didUpdateReferral ? "recordUpdated" : "ready"), pose: .nextStep)
            if let record = model.record {
                ReferralHandoff(record: record, language: model.language)
                let walletState = app.wallet.first(where: { $0.id == record.id })?.state
                if !model.didUpdateReferral && (!kiosk || !app.connected || walletState != .available) {
                    Text(t(app.connected ? (walletState == .available ? "available" : "pending") : "local")).font(.footnote).foregroundStyle(.secondary)
                }
                if app.connected && (!kiosk || walletState != .available) {
                    Button(t("sync")) { Task { await app.sync() } }.buttonStyle(.bordered).disabled(app.busy)
                    if let message = app.message { Text(message).font(.footnote) }
                }
            }
            if kiosk { primary(t("bookAppointment")) { model.step = 8 } }
        case 8:
            AppointmentBookingView(model: model, app: app)
        default: EmptyView()
        }
    }
    private func heading(_ text: String) -> some View { Text(text).font(.largeTitle.weight(.bold)).foregroundStyle(EdgeCareStyle.graphite).accessibilityAddTraits(.isHeader).fixedSize(horizontal: false, vertical: true) }
    private var languagePicker: some View {
        Picker(t("language"), selection: Binding(get: { model.language }, set: { model.languageChosen = true; model.language = $0 })) {
            ForEach(Array(zip(Copy.languages, Copy.names)), id: \.0) { code, name in Text(name).tag(code) }
            if !Copy.languages.contains(model.language) { Text(model.language.uppercased()).tag(model.language) }
        }.pickerStyle(.menu).accessibilityLabel(t("language"))
    }
    /// Heading with Edi beside it, as on the patient intake study.
    private func guideHeading(_ text: String, pose: EdiView.Pose) -> some View {
        HStack(alignment: .center, spacing: 16) {
            EdiView(pose: pose).frame(width: 64, height: 66)
            heading(text)
        }
    }
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title) }
            .buttonStyle(.edgeCarePrimary).disabled(model.busy)
    }
    private var welcomeIntro: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading(t("welcome"))
            Text(t("anonymous")).font(.title3.weight(.semibold)).foregroundStyle(EdgeCareStyle.graphite)
            if !kiosk { Text(t("privacy")).foregroundStyle(.secondary) }
            Text(t("language")).font(.headline).foregroundStyle(EdgeCareStyle.graphite)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) { welcomeLanguages }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], alignment: .leading, spacing: 12) {
                    welcomeLanguages
                }
            }
            primary(t(kiosk ? "createNew" : "start")) { model.step = 1 }
            if kiosk {
                if dynamicTypeSize.isAccessibilitySize || horizontalSizeClass == .compact {
                    VStack(spacing: 12) { secondaryWelcomeActions }
                } else {
                    HStack(spacing: 12) { secondaryWelcomeActions }
                }
                DisclosureGroup(t("privacyDetails")) {
                    Text(t("privacy")).font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
                }.font(.subheadline)
            }
        }
    }
    @ViewBuilder private var secondaryWelcomeActions: some View {
        Button(t("updateExisting")) { model.step = -1 }.buttonStyle(EdgeCareSecondaryButtonStyle(fullWidth: true))
        Button(t("bookAppointment")) { model.step = 8 }.buttonStyle(EdgeCareSecondaryButtonStyle(fullWidth: true))
    }
    @ViewBuilder private var welcomeLanguages: some View {
        ForEach(Array(zip(Copy.languages, Copy.names)), id: \.0) { code, name in
            let selected = model.language.lowercased().hasPrefix(code)
            Button { model.languageChosen = true; model.language = code } label: {
                Text(name).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
            }
            .buttonStyle(LanguageChipStyle(selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
    private var emergencyNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(t("emergencyAdvice"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Link(destination: URL(string: "tel:112")!) {
                Label(t("callEmergency"), systemImage: "phone.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.borderedProminent).tint(.red)
        }.padding(16).background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    private func safetyQuestion(_ question: SafetyQuestion) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if !kiosk { Text(t("tailoredSafety")).font(.subheadline).foregroundStyle(.secondary) }
            Text("\(model.safety.currentIndex + 1) / \(model.safety.totalCount)").font(.caption)
            guideHeading(t(question.copyKey), pose: .listening)
            ForEach(["yes", "no", "unsure"], id: \.self) { answer in
                let chosen = model.safety.answers[question.id.rawValue] == answer
                Button {
                    speech.stop()
                    if let answer = SafetyAnswer(rawValue: answer) { model.answerSafetyQuestion(answer) }
                } label: {
                    HStack {
                        Text(t(answer)); Spacer()
                        Image(systemName: chosen ? "checkmark.circle.fill" : "chevron.forward")
                            .foregroundStyle(chosen ? EdgeCareStyle.accent : Color.secondary)
                    }
                }.buttonStyle(EdgeCareRowButtonStyle(selected: chosen))
                    .accessibilityAddTraits(chosen ? .isSelected : [])
            }
            speechControls(prompt: t(question.copyKey), input: false)
        }
    }
    private func speechControls(prompt: String, input: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    model.lastActivity = Date()
                    if speech.speaking { speech.stop() } else { speech.speak(prompt, language: model.language) }
                } label: { Label(t(speech.speaking ? "stopReading" : "read"), systemImage: speech.speaking ? "stop.circle.fill" : "speaker.wave.2") }
                    .accessibilityIdentifier("readAloud")
                if input {
                    Button {
                        if speech.listening { speech.stop() }
                        else { Task { await speech.start(language: model.language) { model.concern = $0; model.lastActivity = Date() } } }
                    } label: { Label(t(speech.listening ? "stop" : "speak"), systemImage: speech.listening ? "stop.circle" : "mic") }
                }
            }.buttonStyle(.edgeCareSecondary)
            if speech.unavailable || speech.speaking {
                Text(t(speech.unavailable ? "speechUnavailable" : speech.playbackStarted ? "readingAloud" : "preparingReadAloud"))
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("readAloudStatus")
            } else if input && !kiosk {
                Text(t("speechPrivacy")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var safetySources: some View {
        VStack(alignment: .leading, spacing: 8) {
            Link("NHS · cancer information", destination: URL(string: "https://www.nhs.uk/conditions/cancer/")!)
            Link("HUS · urgent and emergency care in Finland", destination: URL(string: "https://www.hus.fi/en/patient/treatments-and-examinations/prehospital-emergency-care")!)
            Link("NHS · breathing symptoms", destination: URL(string: "https://www.nhs.uk/symptoms/shortness-of-breath/")!)
        }.font(.footnote)
    }
    private func useSampleCredentials() {
        model.strokes = DemoData.signatureStrokes(); model.passcode = "1234"; model.confirmation = "1234"
        model.lastActivity = Date()
    }
    private func reset() { speech.stop(); model.reset(); idleSoon = false; app.message = nil }
}
