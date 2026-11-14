import SwiftUI
import EdgeCareCore

/// Live translated consultation → bilingual review → dual confirmation → CRM.
/// Shown full-screen over the verified referral so verification state is preserved underneath.
struct ConsultationView: View {
    @State private var controller: ConsultationController
    @State private var reviewTab = "doctor"
    @State private var confirmDiscard = false
    @State private var disputeNote = ""
    @State private var showDispute = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(record: ReferralRecord, session: NativeSession) {
        _controller = State(initialValue: ConsultationController(record: record, session: session))
    }
    private func p(_ key: String) -> String { Copy.text(key, controller.patientLanguage) }
    private var patientDirection: LayoutDirection { controller.patientLanguage.hasPrefix("ar") ? .rightToLeft : .leftToRight }
    private func name(_ code: String) -> String { Copy.names[Copy.languages.firstIndex(of: code) ?? 0] }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Consultation")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if case .finished = controller.phase { Button("Done") { dismiss() } }
                        else { Button("Close", role: .cancel) { if controller.segments.isEmpty { controller.discardAll(); dismiss() } else { confirmDiscard = true } } }
                    }
                }
                .confirmationDialog("Discard this consultation?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("Discard transcript and notes", role: .destructive) { controller.discardAll(); dismiss() }
                } message: { Text("Nothing has been saved to the CRM yet. The transcript exists only on this screen.") }
        }
        .tint(EdgeCareStyle.mulberry)
        .interactiveDismissDisabled()
        .onChange(of: scenePhase) { _, phase in if phase != .active { controller.suspend() } }
        .onDisappear { controller.teardown() }
        #if DEBUG
        .task { await controller.debugAutostartIfRequested() }
        #endif
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .consent: consent
        case .connecting: ProgressView("Connecting live transcription…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .live, .paused: live
        case .drafting: ProgressView("Writing the visit summary from the transcript…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .review, .submitting: reviewView
        case .finished(let outcome): finished(outcome)
        }
    }

    // MARK: Consent

    private var consent: some View {
        Form {
            Section {
                Picker(selection: $controller.doctorLanguage) {
                    ForEach(Array(zip(Copy.languages, Copy.names)), id: \.0) { code, name in Text(name).tag(code) }
                } label: { Label("Clinician speaks", systemImage: "stethoscope") }
                Picker(selection: $controller.patientLanguage) {
                    ForEach(Array(zip(Copy.languages, Copy.names)), id: \.0) { code, name in Text(name).tag(code) }
                } label: { Label("Patient speaks", systemImage: "person.fill") }
                Picker("Speaks first", selection: Binding(get: { controller.activeSpeaker }, set: { controller.setSpeaker($0) })) {
                    Text("Clinician").tag(ConsultationSpeaker.doctor)
                    Text("Patient").tag(ConsultationSpeaker.patient)
                }
                Label {
                    if controller.sameLanguage {
                        Text("**Same language** \u{00B7} no translation. Tap the speaker switch when the other person starts talking.")
                    } else {
                        Text("**\(name(controller.doctorLanguage)) \u{2194} \(name(controller.patientLanguage))** \u{00B7} who is speaking is detected from the language. After each pause the sentence is translated and read aloud. The speaker switch stays available for short replies.")
                    }
                } icon: { Image(systemName: controller.sameLanguage ? "hand.tap" : "character.bubble") }
                .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Set up the visit") } footer: {
                Text("At the end, a summary is written from the transcript. You and the patient confirm it, then it is saved to the health record.")
            }
            Section(p("consultTitle")) {
                Text(p("consultConsent")).environment(\.layoutDirection, patientDirection)
                if controller.patientLanguage != "en" {
                    Text(Copy.text("consultConsent", "en")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Button { Task { await controller.begin() } } label: {
                    Label("\(p("consultAgree")) · Start", systemImage: "waveform.and.mic")
                }.buttonStyle(.borderedProminent).frame(minHeight: 48)
                Text("Only start after the patient agrees. Audio is streamed for translation and never stored.").font(.footnote).foregroundStyle(.secondary)
                if let error = controller.error { Text(error).foregroundStyle(.red) }
            }
        }
    }

    // MARK: Live

    private var live: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroller in
            List {
                Section {
                    Label(controller.phase == .paused ? "Paused · microphone off" : "Listening", systemImage: controller.phase == .paused ? "pause.circle" : "waveform")
                        .foregroundStyle(controller.phase == .paused ? Color.orange : EdgeCareStyle.mulberry).font(.headline)
                    Text(p("consultListening")).environment(\.layoutDirection, patientDirection)
                    if controller.phase == .live { micStatus }
                    if let error = controller.error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                Section("Conversation") {
                    if controller.segments.isEmpty && controller.partial.isEmpty { Text("Nothing said yet.").foregroundStyle(.secondary) }
                    ForEach(controller.segments) { segment in segmentRow(segment) }
                    if !controller.partial.isEmpty { Text(controller.partial).italic().foregroundStyle(.secondary).id("partial") }
                    Color.clear.frame(height: 1).listRowBackground(Color.clear).id("latest")
                }
                if !controller.unclear.isEmpty {
                    Section(p("consultRepeat")) {
                        ForEach(controller.unclear) { utterance in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(utterance.text)
                                Text("Language not recognised as either participant's. Not translated or spoken.").font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Clinician said this") { controller.assign(utterance, to: .doctor) }
                                    Button("Patient said this") { controller.assign(utterance, to: .patient) }
                                    Spacer()
                                    Button("Discard", role: .destructive) { controller.discard(utterance) }
                                }.buttonStyle(.bordered).font(.caption)
                            }
                        }
                    }
                }
            }
            // Keep the newest sentence and its translation in view as the conversation grows.
            .onChange(of: controller.segments) { _, _ in withAnimation { scroller.scrollTo("latest", anchor: .bottom) } }
            .onChange(of: controller.partial.isEmpty) { _, _ in withAnimation { scroller.scrollTo("latest", anchor: .bottom) } }
            }
            SpeakerToggle(active: controller.activeSpeaker, caption: speakerCaption) { controller.setSpeaker($0) }
                .padding(.horizontal).padding(.top, 12)
                .frame(maxWidth: .infinity).background(.bar)
            HStack(spacing: 12) {
                if controller.phase == .paused {
                    Button { Task { await controller.resume() } } label: { Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                } else {
                    Button { controller.pause() } label: { Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
                Button { Task { await controller.end() } } label: { Label("End & review", systemImage: "checkmark.rectangle.stack").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(!controller.canEnd)
            }
            .frame(minHeight: 48).padding()
            .background(.bar)
        }
    }

    private var speakerCaption: String {
        if controller.sameLanguage { return "Tap who is speaking" }
        switch controller.speakerSource {
        case .detected(let language): return "Auto \u{00B7} heard \(name(language))"
        case .manual: return "Set by tap \u{00B7} switches when a language is heard"
        }
    }

    @ViewBuilder private var micStatus: some View {
        switch controller.micHealth {
        case .ok:
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").foregroundStyle(.secondary)
                ProgressView(value: Double(min(1, controller.inputLevel * 4))).tint(EdgeCareStyle.mulberry)
                    .accessibilityLabel("Microphone level")
            }.font(.footnote)
        case .silent:
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The microphone is sending silence.").fontWeight(.semibold)
                    #if targetEnvironment(simulator)
                    Text("Simulator: allow the microphone for Xcode/Simulator in macOS Privacy & Security, and check the Simulator's audio input device.")
                    #else
                    Text("Check that no other app is using the microphone and that it is not covered.")
                    #endif
                }
            } icon: { Image(systemName: "mic.slash.fill") }
            .font(.footnote).foregroundStyle(.orange)
        case .stalled:
            Label("Microphone stopped. Restarting\u{2026} If this persists, tap Pause then Resume.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.orange)
        }
    }

    private func segmentRow(_ segment: ConsultationSegment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(segment.speaker == .doctor ? "CLINICIAN" : "PATIENT").font(.caption.weight(.bold))
                    .foregroundStyle(segment.speaker == .doctor ? EdgeCareStyle.mulberry : EdgeCareStyle.magenta)
                if segment.sourceLanguage != segment.targetLanguage {
                    Text("\(segment.sourceLanguage.uppercased()) → \(segment.targetLanguage.uppercased())").font(.caption2).foregroundStyle(.secondary)
                }
                if segment.speakerOverridden { Text("speaker corrected").font(.caption2).foregroundStyle(.orange) }
                Spacer()
                Menu {
                    if segment.sourceLanguage == segment.targetLanguage {
                        Button("Swap speaker") { controller.swapSpeaker(seq: segment.seq) }
                    } else {
                        Button("Swap speaker and re-translate") { controller.swapSpeaker(seq: segment.seq) }
                        Button("Play translation again") { controller.replay(seq: segment.seq) }.disabled(segment.translatedText.isEmpty)
                    }
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Sentence options") }
            }
            Text(segment.originalText).environment(\.layoutDirection, segment.sourceLanguage.hasPrefix("ar") ? .rightToLeft : .leftToRight)
            if controller.translating.contains(segment.seq) { ProgressView().controlSize(.small) }
            else if !segment.translatedText.isEmpty, segment.sourceLanguage != segment.targetLanguage {
                Text(segment.translatedText).fontWeight(.medium)
                    .environment(\.layoutDirection, segment.targetLanguage.hasPrefix("ar") ? .rightToLeft : .leftToRight)
            }
        }.padding(.vertical, 4)
    }

    // MARK: Review and dual confirmation

    private var reviewView: some View {
        VStack(spacing: 0) {
            Picker("Reviewer", selection: $reviewTab) {
                Text("Clinician (English notes)").tag("doctor")
                Text(name(controller.patientLanguage)).tag("patient")
            }.pickerStyle(.segmented).padding()
            if reviewTab == "doctor" { doctorReview } else { patientReview }
        }
    }

    private func field(_ title: String, _ keyPath: WritableKeyPath<ConsultationNotesDraft, String>, axis: Axis = .vertical) -> some View {
        TextField(title, text: Binding(
            get: { controller.review?.draft[keyPath: keyPath] ?? "" },
            set: { value in guard var review = controller.review else { return }; var draft = review.draft; draft[keyPath: keyPath] = value; review.editByClinician(draft); controller.review = review }
        ), axis: axis).lineLimit(1...6)
    }
    private func listField(_ title: String, _ keyPath: WritableKeyPath<ConsultationNotesDraft, [String]>) -> some View {
        TextField(title, text: Binding(
            get: { controller.review?.draft[keyPath: keyPath].joined(separator: ", ") ?? "" },
            set: { value in
                guard var review = controller.review else { return }
                var draft = review.draft
                draft[keyPath: keyPath] = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                review.editByClinician(draft); controller.review = review
            }
        ), axis: .vertical).lineLimit(1...4)
    }

    @ViewBuilder private var doctorReview: some View {
        if let review = controller.review {
            Form {
                if let error = controller.error {
                    Section { Text(error).foregroundStyle(.red); Button("Retry drafting notes") { Task { await controller.retryDraft() } }.disabled(controller.regenerating) }
                }
                if !review.draft.discrepancies.isEmpty || !review.disputedItems.isEmpty {
                    Section("Check before confirming") {
                        ForEach(review.draft.discrepancies, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                        ForEach(review.disputedItems, id: \.self) { Label($0, systemImage: "person.fill.questionmark").foregroundStyle(.orange) }
                    }
                }
                Section("Structured notes for the CRM") {
                    field("Presenting complaint", \.structured.presentingComplaint)
                    listField("Symptoms (comma separated)", \.structured.symptoms)
                    field("Duration", \.structured.duration)
                    field("Relevant history", \.structured.relevantHistory)
                    field("Examination findings", \.structured.examinationFindings)
                    field("Clinician assessment (your words only)", \.structured.clinicianAssessment)
                    field("Plan", \.structured.plan)
                    field("Follow-up", \.structured.followUp)
                    listField("Medications mentioned", \.structured.medicationsMentioned)
                    listField("Safety concerns", \.structured.safetyConcerns)
                    TextField("Recommended specialty", text: Binding(
                        get: { controller.review?.draft.structured.recommendedSpecialty ?? "" },
                        set: { value in guard var review = controller.review else { return }; var draft = review.draft; draft.structured.recommendedSpecialty = value.isEmpty ? nil : value; review.editByClinician(draft); controller.review = review }))
                }
                Section {
                    field("Clinical summary", \.clinicalSummary)
                    field("Key points (one per line)", \.meetingNotes)
                } header: { Text("Summary and key points") } footer: {
                    Text("This summary and these key points are what is saved to the health record. The full conversation is not saved.")
                }
                if review.patientSummaryStale {
                    Section {
                        Label("Your edits are not yet in the patient's summary. Update it before the patient confirms.", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                        Button { Task { await controller.regenerateSummaries() } } label: {
                            if controller.regenerating { ProgressView() } else { Text("Update patient summary") }
                        }.disabled(controller.regenerating)
                    }
                }
                Section("Conversation (not saved)") {
                    Text("Used only to check the summary. Flag any sentence the patient or you think was mistranslated, and enter the correct meaning; the summary is then rewritten.").font(.footnote).foregroundStyle(.secondary)
                    ForEach(review.segments) { segment in TranscriptReviewRow(segment: segment) { flagged, correction in
                        guard var current = controller.review else { return }
                        current.setFlag(seq: segment.seq, flagged: flagged, correction: correction); controller.review = current
                    } }
                }
                Section("Confirm") {
                    confirmationStatus(review)
                    Button { guard var current = controller.review else { return }; current.confirmDoctor(); controller.review = current } label: {
                        Label("I confirm these notes are accurate", systemImage: review.doctorConfirmedAt == nil ? "checkmark.circle" : "checkmark.circle.fill")
                    }.frame(minHeight: 44).disabled(review.doctorConfirmedAt != nil)
                    Button { Task { await controller.submit() } } label: {
                        if controller.phase == .submitting { ProgressView() } else { Label("Save to CRM", systemImage: "tray.and.arrow.up") }
                    }.buttonStyle(.borderedProminent).frame(minHeight: 48).disabled(!review.canSubmit || controller.phase == .submitting)
                    if !review.canSubmit { Text("Saving needs both the patient's and your confirmation of the current version. Any edit clears both.").font(.footnote).foregroundStyle(.secondary) }
                    Button("Resume translated conversation") { Task { await controller.begin() } }
                }
            }
        }
    }

    private func confirmationStatus(_ review: ConsultationReview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(review.patientConfirmedAt == nil ? "Patient has not confirmed" : "Patient confirmed", systemImage: review.patientConfirmedAt == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(review.patientConfirmedAt == nil ? Color.secondary : Color.green)
            Label(review.doctorConfirmedAt == nil ? "Clinician has not confirmed" : "Clinician confirmed", systemImage: review.doctorConfirmedAt == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(review.doctorConfirmedAt == nil ? Color.secondary : Color.green)
        }.font(.subheadline)
    }

    @ViewBuilder private var patientReview: some View {
        if let review = controller.review {
            Form {
                Section {
                    Text(p("consultConfirmPrompt")).font(.title3.weight(.semibold))
                    if review.patientSummaryStale || controller.regenerating { Label(p("consultWaiting"), systemImage: "hourglass") }
                    else {
                        Text(review.draft.patientLanguageSummary.isEmpty ? "—" : review.draft.patientLanguageSummary).font(.body)
                        if !review.draft.meetingNotesPatientLanguage.isEmpty { Text(review.draft.meetingNotesPatientLanguage).foregroundStyle(.secondary) }
                        Button { Task { await controller.readSummaryAloud() } } label: {
                            if controller.speaking { ProgressView() } else { Label(p("read"), systemImage: "speaker.wave.2") }
                        }.frame(minHeight: 44).disabled(controller.speaking)
                    }
                }
                Section {
                    if review.patientConfirmedAt != nil {
                        Label(p("consultPatientConfirmed"), systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.headline)
                    } else {
                        Button { guard var current = controller.review else { return }; try? current.confirmPatient(); controller.review = current } label: {
                            Label(p("consultConfirmYes"), systemImage: "hand.thumbsup.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(.green).frame(minHeight: 56).disabled(!review.canPatientConfirm)
                        Button { showDispute = true } label: {
                            Label(p("consultConfirmNo"), systemImage: "hand.raised.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).frame(minHeight: 56)
                    }
                    if showDispute {
                        Text(p("consultDisputeHint"))
                    }
                }
            }
            .environment(\.layoutDirection, patientDirection)
            .safeAreaInset(edge: .bottom) {
                if showDispute {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Clinician: note what the patient says is wrong (optional), then talk it through with translation.").font(.footnote)
                        TextField("What is wrong (English)", text: $disputeNote).textFieldStyle(.roundedBorder)
                        Button { Task { let note = disputeNote; disputeNote = ""; showDispute = false; reviewTab = "doctor"; await controller.patientDisputes(note) } } label: {
                            Label("Resume translated conversation", systemImage: "waveform.and.mic").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).frame(minHeight: 48)
                    }.padding().background(.bar).environment(\.layoutDirection, .leftToRight)
                }
            }
        }
    }

    // MARK: Done

    private func finished(_ outcome: NativeSession.ConsultationSubmission) -> some View {
        VStack(spacing: 18) {
            Image(systemName: outcome == .saved ? "checkmark.seal.fill" : "clock.badge.checkmark").font(.system(size: 56)).foregroundStyle(outcome == .saved ? .green : .orange)
            Text(outcome == .saved ? "Saved to the CRM" : "Saved on this phone · will upload when online").font(.title2.weight(.bold)).multilineTextAlignment(.center)
            Text(outcome == .saved ? "The consultation is attached to this referral with both confirmations. The original triage was not changed." : "The confirmed consultation is encrypted on this device and uploads on the next sync.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text(p("consultSaved")).multilineTextAlignment(.center).environment(\.layoutDirection, patientDirection)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent).frame(minHeight: 48)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One transcript line in review: flag a mistranslation and record the correct meaning.
private struct TranscriptReviewRow: View {
    let segment: ConsultationSegment
    let onChange: (Bool, String?) -> Void
    @State private var correction: String
    init(segment: ConsultationSegment, onChange: @escaping (Bool, String?) -> Void) {
        self.segment = segment; self.onChange = onChange; _correction = State(initialValue: segment.correction ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(segment.speaker == .doctor ? "CLINICIAN" : "PATIENT").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Text(segment.originalText)
            if segment.sourceLanguage != segment.targetLanguage {
                Text(segment.translatedText.isEmpty ? "No translation" : segment.translatedText).foregroundStyle(.secondary)
            }
            Toggle(segment.sourceLanguage == segment.targetLanguage ? "Transcribed incorrectly" : "Mistranslated", isOn: Binding(get: { segment.flagged }, set: { onChange($0, $0 ? correction : nil) }))
            if segment.flagged {
                TextField("Correct meaning", text: $correction, axis: .vertical)
                    .onSubmit { onChange(true, correction) }
                Button("Save correction") { onChange(true, correction) }.font(.caption).disabled(correction.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(.vertical, 4)
    }
}

/// Two-position "who is speaking" switch. One tap hands the floor over; in two-language visits it
/// also moves on its own when the other participant's language is detected.
private struct SpeakerToggle: View {
    let active: ConsultationSpeaker
    var caption: String? = nil
    let select: (ConsultationSpeaker) -> Void
    @Namespace private var thumb

    var body: some View {
        VStack(spacing: 6) {
            Text("Now speaking").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            HStack(spacing: 0) {
                side(.patient, "Patient", "person.fill")
                side(.doctor, "Clinician", "stethoscope")
            }
            .padding(4)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .sensoryFeedback(.selection, trigger: active)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: active)
            if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    private func side(_ speaker: ConsultationSpeaker, _ title: String, _ icon: String) -> some View {
        let on = active == speaker
        let tint = speaker == .doctor ? EdgeCareStyle.mulberry : EdgeCareStyle.magenta
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { select(speaker) }
        } label: {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(on ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background {
                    if on { Capsule().fill(tint).matchedGeometryEffect(id: "thumb", in: thumb) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
