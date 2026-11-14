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
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .consent: consent
        case .connecting: ProgressView("Connecting translation and recording…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .live, .paused: live
        case .drafting: ProgressView("Drafting notes from both transcripts…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .review, .submitting: reviewView
        case .finished(let outcome): finished(outcome)
        }
    }

    // MARK: Consent

    private var consent: some View {
        Form {
            Section("Languages") {
                Picker("Clinician speaks", selection: $controller.doctorLanguage) {
                    ForEach(Array(zip(Copy.languages, Copy.names)), id: \.0) { code, name in Text(name).tag(code) }
                }
                Picker("Patient speaks", selection: $controller.patientLanguage) {
                    ForEach(Array(zip(Copy.languages, Copy.names)), id: \.0) { code, name in Text(name).tag(code) }
                }
                Text("The speaker is detected from the language spoken. You can correct it on any sentence.").font(.footnote).foregroundStyle(.secondary)
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
                    .disabled(controller.doctorLanguage == controller.patientLanguage)
                Text("Only start after the patient agrees. Audio is streamed for translation and never stored.").font(.footnote).foregroundStyle(.secondary)
                if let error = controller.error { Text(error).foregroundStyle(.red) }
            }
        }
    }

    // MARK: Live

    private var live: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    Label(controller.phase == .paused ? "Paused · microphone off" : "Listening", systemImage: controller.phase == .paused ? "pause.circle" : "waveform")
                        .foregroundStyle(controller.phase == .paused ? Color.orange : EdgeCareStyle.mulberry).font(.headline)
                    Text(p("consultListening")).environment(\.layoutDirection, patientDirection)
                    Label(controller.recordingStatus, systemImage: "record.circle").font(.footnote).foregroundStyle(.secondary)
                    if let error = controller.error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                Section("Conversation") {
                    if controller.segments.isEmpty && controller.partial.isEmpty { Text("Nothing said yet.").foregroundStyle(.secondary) }
                    ForEach(controller.segments) { segment in segmentRow(segment) }
                    if !controller.partial.isEmpty { Text(controller.partial).italic().foregroundStyle(.secondary) }
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
                if !controller.keyPoints.isEmpty {
                    Section("Key points (Gemini Live recorder)") {
                        ForEach(Array(controller.keyPoints.enumerated()), id: \.offset) { _, point in Label(point, systemImage: "text.badge.checkmark").font(.subheadline) }
                    }
                }
            }
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

    private func segmentRow(_ segment: ConsultationSegment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(segment.speaker == .doctor ? "CLINICIAN" : "PATIENT").font(.caption.weight(.bold))
                    .foregroundStyle(segment.speaker == .doctor ? EdgeCareStyle.mulberry : EdgeCareStyle.magenta)
                Text("\(segment.sourceLanguage.uppercased()) → \(segment.targetLanguage.uppercased())").font(.caption2).foregroundStyle(.secondary)
                if segment.speakerOverridden { Text("speaker corrected").font(.caption2).foregroundStyle(.orange) }
                Spacer()
                Menu {
                    Button("Swap speaker and re-translate") { controller.swapSpeaker(seq: segment.seq) }
                    Button("Play translation again") { controller.replay(seq: segment.seq) }.disabled(segment.translatedText.isEmpty)
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Sentence options") }
            }
            Text(segment.originalText).environment(\.layoutDirection, segment.sourceLanguage.hasPrefix("ar") ? .rightToLeft : .leftToRight)
            if controller.translating.contains(segment.seq) { ProgressView().controlSize(.small) }
            else if !segment.translatedText.isEmpty {
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
                Section("Clinical summary and meeting notes") {
                    field("Clinical summary", \.clinicalSummary)
                    field("Meeting notes (anything unstructured)", \.meetingNotes)
                }
                if review.patientSummaryStale {
                    Section {
                        Label("Your edits are not yet in the patient's summary. Update it before the patient confirms.", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                        Button { Task { await controller.regenerateSummaries() } } label: {
                            if controller.regenerating { ProgressView() } else { Text("Update patient summary") }
                        }.disabled(controller.regenerating)
                    }
                }
                Section("Transcript and translations") {
                    Text("Flag any sentence the patient or you think was mistranslated, and enter the correct meaning.").font(.footnote).foregroundStyle(.secondary)
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
            Text(segment.translatedText.isEmpty ? "No translation" : segment.translatedText).foregroundStyle(.secondary)
            Toggle("Mistranslated", isOn: Binding(get: { segment.flagged }, set: { onChange($0, $0 ? correction : nil) }))
            if segment.flagged {
                TextField("Correct meaning", text: $correction, axis: .vertical)
                    .onSubmit { onChange(true, correction) }
                Button("Save correction") { onChange(true, correction) }.font(.caption).disabled(correction.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(.vertical, 4)
    }
}
