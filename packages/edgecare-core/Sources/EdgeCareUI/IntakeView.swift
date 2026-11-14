import SwiftUI
import Observation
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
    public var urgent: String?
    public var persistent: String?
    public var letterText = ""
    public var lesionPresent = false
    public var strokes: [[SignaturePoint]] = []
    public var passcode = ""
    public var confirmation = ""
    public var understood = false
    public var record: ReferralRecord?
    public var error: String?
    public var languageChosen = false
    public var languageDetected = false
    public var lastActivity = Date()
    private var generation = 0
    public let source: ReferralSource
    private let triage: any TriageEngine
    public init(source: ReferralSource = .patientApp, triage: any TriageEngine = OnDeviceTriageEngine()) { self.source = source; self.triage = triage }
    public func continueFlow() async {
        let currentGeneration = generation
        busy = true; defer { if generation == currentGeneration { busy = false } }
        let structured = "\(clinicalProfile.clinicianSummary)\n\(concern)\n[urgent_now=\(urgent ?? "unsure")]\n[persistent_or_changing=\(persistent ?? "unsure")]" + (letterText.isEmpty ? "" : "\nScreening letter: \(letterText)") + (lesionPresent ? "\nSkin concern photo noted; no image model assessment." : "")
        do {
            let result = try await triage.guidance(for: structured, language: language)
            guard generation == currentGeneration else { return }
            guidance = result; step = 5
        }
        catch { if generation == currentGeneration { self.error = Copy.text("error", language) } }
    }
    public func enroll(using app: AppSession) async {
        guard let session = app.session, let guidance else { error = Copy.text("error", language); return }
        guard passcode.count == 4, passcode == confirmation, understood else { error = Copy.text("pinMismatch", language); return }
        let currentGeneration = generation
        busy = true; defer { if generation == currentGeneration { busy = false } }
        do {
            let draft = EnrollmentDraft(source: source, language: language, concern: clinicalProfile.clinicianSummary + "\nPatient notes (original language): " + concern, guidance: guidance, letterText: letterText.isEmpty ? nil : letterText, lesionPresent: lesionPresent, answers: ["urgent_now": urgent ?? "unsure", "persistent_or_changing": persistent ?? "unsure"], clinicalProfile: clinicalProfile)
            let sealed = try await session.enroll(draft: draft, strokes: strokes, passcode: passcode, confirmation: confirmation)
            guard generation == currentGeneration else { return }
            record = sealed
            passcode = ""; confirmation = ""; strokes = []; step = 7
            await app.refresh()
        } catch { if generation == currentGeneration { self.error = Copy.text("error", language) + " (\(error))" } }
    }
    public func reset() {
        generation += 1; busy = false
        inputMode = "form"; selectedSymptoms = []; duration = "unknown"; severity = "unknown"; clinicalProfile = ClinicalProfile(); voiceHistory = []; voiceConsent = false; voiceIntakeComplete = false
        concern = ""; guidance = nil; step = 0; urgent = nil; persistent = nil; letterText = ""; lesionPresent = false
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
    @State private var idleSoon = false
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    public init(title: String, model: IntakeViewModel, app: AppSession, kiosk: Bool = false) {
        self.title = title; self.model = model; self.app = app; self.kiosk = kiosk
    }
    private func t(_ key: String) -> String { Copy.text(key, model.language) }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    SessionBanner(connected: app.connected, language: model.language)
                    Spacer()
                    Picker(t("language"), selection: Binding(get: { model.language }, set: { model.languageChosen = true; model.language = $0 })) {
                        ForEach(Array(zip(Copy.languages, Copy.names)), id: \.0) { code, name in Text(name).tag(code) }
                        if !Copy.languages.contains(model.language) { Text(model.language.uppercased()).tag(model.language) }
                    }.pickerStyle(.menu).accessibilityLabel(t("language"))
                }
                if model.step > 0 && model.step < 7 {
                    ProgressView(value: Double(model.step), total: 7).tint(EdgeCareStyle.magenta)
                        .accessibilityLabel("\(model.step) / 7")
                }
                if app.session == nil, let message = app.message { Text(message).foregroundStyle(.red) }
                content
                if let error = model.error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                if model.busy { ProgressView(t("saving")) }
                if model.step > 0 {
                    HStack {
                        if model.step < 7 && model.step > 1 {
                            Button(t("back")) { speech.stop(); model.step -= 1; model.error = nil }.buttonStyle(.bordered).frame(minHeight: 48)
                        }
                        Spacer()
                        Button(t("end"), role: .destructive) { reset() }.frame(minHeight: 48)
                    }
                }
                if kiosk { Text(t(idleSoon ? "idleSoon" : "idle")).font(.footnote).foregroundStyle(idleSoon ? .primary : .secondary) }
            }.padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .background(.background)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .environment(\.layoutDirection, model.language.lowercased().hasPrefix("ar") ? .rightToLeft : .leftToRight)
        .onChange(of: model.language) { _, language in model.lastActivity = Date(); speech.stop(); app.language = language }
        .onChange(of: model.concern) { _, text in
            model.lastActivity = Date()
            if !model.languageChosen, !model.languageDetected, let language = detectedLanguage(text) {
                model.language = language; model.languageDetected = true
            }
        }
        .onChange(of: model.step) { _, _ in model.lastActivity = Date(); speech.stop() }
        .onChange(of: model.letterText) { _, _ in model.lastActivity = Date() }
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
            ToolbarItem {
                Menu(t("demoControls")) {
                    if app.connected { Toggle(t("simulateOffline"), isOn: $app.simulateOffline) }
                    Button(t("sync")) { Task { await app.sync() } }.disabled(app.busy)
                }
            }
        }
        .onDisappear { speech.stop(); model.passcode = ""; model.confirmation = "" }
    }
    @ViewBuilder private var content: some View {
        switch model.step {
        case 0:
            Image(systemName: "hand.raised.heart").font(.system(size: 48)).foregroundStyle(EdgeCareStyle.mulberry).accessibilityHidden(true)
            heading(t("welcome"))
            Text(t("anonymous")).font(.title3.weight(.semibold))
            Text(t("privacy")).foregroundStyle(.secondary)
            primary(t("start")) { model.step = 1 }
        case 1:
            heading(t("concernTitle"))
            Text(t("anonymous")).foregroundStyle(.secondary)
            Picker(t("inputMode"), selection: $model.inputMode) {
                Text(t("form")).tag("form")
                Text(t("conversation")).tag("voice")
            }.pickerStyle(.segmented)
            if model.inputMode == "voice" {
                ConversationView(model: model, app: app)
            } else {
                StructuredConcernForm(model: model)
                if model.languageDetected { Text(t("detected")).font(.footnote) }
                speechControls(prompt: t("concernTitle"), input: true)
            }
            primary(t("next")) { model.step = 2 }
                .disabled(model.inputMode == "form" ? model.selectedSymptoms.isEmpty : model.clinicalProfile.concernEnglish.isEmpty)

        case 2:
            question("urgentQuestion", selection: $model.urgent, next: 3)
        case 3:
            question("changeQuestion", selection: $model.persistent, next: 4)
        case 4:
            heading(t("evidence"))
            EvidenceCapture(language: model.language, letterText: $model.letterText, lesionPresent: $model.lesionPresent)
            primary(t("next")) { Task { await model.continueFlow() } }.disabled(model.busy)
        case 5:
            heading(t("guidance"))
            if let guidance = model.guidance {
                Text(guidance.message).font(.title3)
                Text(t("review")).font(.subheadline).foregroundStyle(.secondary)
                speechControls(prompt: guidance.message, input: false)
                safetySources
                if guidance.requiresEmergencyHelp {
                    Link(destination: URL(string: "tel:112")!) { Label("112", systemImage: "phone.fill").font(.title2).frame(maxWidth: .infinity, minHeight: 56) }.buttonStyle(.borderedProminent).tint(.red)
                } else { primary(t("seal")) { model.step = 6 } }
            }
        case 6:
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
            DisclosureGroup(t("demoDisclosure")) {
                Text(t("demoDetail")).font(.caption)
                Button(t("demoUse")) {
                    model.strokes = DemoData.signatureStrokes(); model.passcode = "1234"; model.confirmation = "1234"
                }.frame(minHeight: 48)
            }.font(.footnote)
        case 7:
            heading(t("ready"))
            if let record = model.record {
                ReferralHandoff(record: record, language: model.language)
                let walletState = app.wallet.first(where: { $0.id == record.id })?.state
                Text(t(app.connected ? (walletState == .available ? "available" : "pending") : "local")).font(.footnote).foregroundStyle(.secondary)
                if app.connected {
                    Button(t("sync")) { Task { await app.sync() } }.buttonStyle(.bordered).disabled(app.busy)
                    if let message = app.message { Text(message).font(.footnote) }
                }
            }
        default: EmptyView()
        }
    }
    private func heading(_ text: String) -> some View { Text(text).font(.largeTitle.weight(.semibold)).foregroundStyle(EdgeCareStyle.mulberry).accessibilityAddTraits(.isHeader).fixedSize(horizontal: false, vertical: true) }
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 48) }
            .buttonStyle(.borderedProminent).tint(EdgeCareStyle.mulberry).disabled(model.busy)
    }
    private func question(_ key: String, selection: Binding<String?>, next: Int) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            heading(t(key))
            ForEach(["yes", "no", "unsure"], id: \.self) { answer in
                Button {
                    selection.wrappedValue = answer
                    if key == "urgentQuestion" && answer == "yes" { Task { await model.continueFlow() } }
                    else { model.step = next }
                } label: {
                    HStack { Text(t(answer)); Spacer(); if selection.wrappedValue == answer { Image(systemName: "checkmark.circle.fill") } }.frame(minHeight: 48)
                }.buttonStyle(.bordered).tint(EdgeCareStyle.mulberry)
            }
            speechControls(prompt: t(key), input: false)
        }
    }
    private func speechControls(prompt: String, input: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { speech.speak(prompt, language: model.language) } label: { Label(t("read"), systemImage: "speaker.wave.2") }.frame(minHeight: 48)
                if input {
                    Button {
                        if speech.listening { speech.stop() }
                        else { Task { await speech.start(language: model.language) { model.concern = $0; model.lastActivity = Date() } } }
                    } label: { Label(t(speech.listening ? "stop" : "speak"), systemImage: speech.listening ? "stop.circle" : "mic") }.frame(minHeight: 48)
                }
            }.buttonStyle(.bordered)
            Text(t(speech.unavailable ? "speechUnavailable" : "speechPrivacy")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var safetySources: some View {
        VStack(alignment: .leading, spacing: 8) {
            Link("NHS · cancer information", destination: URL(string: "https://www.nhs.uk/conditions/cancer/")!)
            Link("HUS · urgent and emergency care in Finland", destination: URL(string: "https://www.hus.fi/en/patient/treatments-and-examinations/prehospital-emergency-care")!)
        }.font(.footnote)
    }
    private func reset() { speech.stop(); model.reset(); idleSoon = false; app.message = nil }
}
