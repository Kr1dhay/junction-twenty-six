import Foundation
import Observation
import os
import EdgeCareCore
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// On-device backup for Scribe's language detection, limited to the visit's two languages. Used
/// only when Scribe reports no language or a third one; nothing leaves the phone.
enum TextLanguageGuess {
    static func guess(_ text: String, among languages: [String]) -> String? {
        #if canImport(NaturalLanguage)
        guard text.filter(\.isLetter).count >= 8 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languages.map { NLLanguage(rawValue: $0) }
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.8 else { return nil }
        return language.rawValue
        #else
        return nil
        #endif
    }
}

/// An utterance whose language could not be attributed to either participant. It is never
/// translated or spoken until the clinician assigns a speaker.
struct UnclearUtterance: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let language: String?
}

@MainActor @Observable final class ConsultationController {
    enum Phase: Equatable {
        case consent, connecting, live, paused, drafting, review, submitting
        case finished(NativeSession.ConsultationSubmission)
    }
    let record: ReferralRecord
    private let session: NativeSession
    var doctorLanguage: String
    var patientLanguage: String
    private(set) var phase: Phase = .consent
    private(set) var segments: [ConsultationSegment] = []
    private(set) var unclear: [UnclearUtterance] = []
    private(set) var partial: String = ""
    private(set) var translating: Set<Int> = []
    var review: ConsultationReview?
    var error: String?
    private(set) var regenerating = false
    private(set) var speaking = false
    /// Who is talking now. Same-language visits rely on the clinician's toggle; in two-language
    /// visits the detected language moves it automatically, and the toggle is the fallback for
    /// utterances too short to tell the language of.
    private(set) var activeSpeaker: ConsultationSpeaker = .doctor
    /// Why the toggle is where it is (shown under it so the clinician can trust or correct it).
    enum SpeakerSource: Equatable { case manual, detected(language: String) }
    private(set) var speakerSource: SpeakerSource = .manual
    /// Speech in progress when the toggle flips still belongs to the previous speaker.
    private var pendingCommitSpeaker: ConsultationSpeaker?
    /// Live microphone level (0...1) and health, so a dead input never looks like "Listening".
    private(set) var inputLevel: Float = 0
    private(set) var micHealth: MicHealth = .ok

    private let consultationID = UUID().uuidString.lowercased()
    private var startedAt: Date?
    private var resolver: SpeakerResolver
    private let audio = ConsultationAudioEngine()
    private let scribe = RealtimeScribeClient()
    private var tasks: [Task<Void, Never>] = []
    private var nextSeq = 0

    init(record: ReferralRecord, session: NativeSession) {
        self.record = record; self.session = session
        let patient = SpeakerResolver.normalize(record.language)
        let doctor = patient == "en" ? "fi" : "en"
        patientLanguage = patient; doctorLanguage = doctor
        resolver = SpeakerResolver(doctorLanguage: doctor, patientLanguage: patient)
        audio.onInterrupted = { [weak self] in self?.pause() }
    }

    var sameLanguage: Bool { SpeakerResolver.normalize(doctorLanguage) == SpeakerResolver.normalize(patientLanguage) }
    var isActive: Bool { [.connecting, .live, .paused, .drafting, .review, .submitting].contains(phase) }
    var canEnd: Bool { !segments.isEmpty && (phase == .live || phase == .paused) }

    #if DEBUG
    /// Simulator automation only: `EDGECARE_DEBUG_CONSULT_LANGS=en,fi`, `EDGECARE_DEBUG_CONSULT_AUTOSTART=1`,
    /// and `EDGECARE_DEBUG_CONSULT_FINISH=1` (after injected audio: end, both confirm, save to the CRM)
    /// so the full flow can be exercised without taps. The same methods the buttons call are used.
    func debugAutostartIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        if let langs = env["EDGECARE_DEBUG_CONSULT_LANGS"]?.split(separator: ",").map(String.init), langs.count == 2 {
            doctorLanguage = langs[0]; patientLanguage = langs[1]
        }
        guard env["EDGECARE_DEBUG_CONSULT_AUTOSTART"] == "1", phase == .consent else { return }
        await begin()
        guard env["EDGECARE_DEBUG_CONSULT_FINISH"] == "1" else { return }
        while !audio.debugInjectionFinished { try? await Task.sleep(for: .milliseconds(500)) }
        while !translating.isEmpty || audio.isPlaying { try? await Task.sleep(for: .milliseconds(500)) }
        await end()
        guard var current = review else { consultationAudioLog.error("debug: no review"); return }
        consultationAudioLog.info("debug: drafted error=\(self.error ?? "none", privacy: .public) summary=\(current.draft.clinicalSummary, privacy: .public) patient=\(current.draft.patientLanguageSummary, privacy: .public) complaint=\(current.draft.structured.presentingComplaint, privacy: .public)")
        do { try current.confirmPatient() } catch { consultationAudioLog.error("debug: patient cannot confirm"); return }
        current.confirmDoctor(); review = current
        await submit()
        switch phase {
        case .finished(let outcome): consultationAudioLog.info("debug: submitted \(String(describing: outcome), privacy: .public) id=\(self.consultationID, privacy: .public)")
        default: consultationAudioLog.error("debug: submit failed \(self.error ?? "?", privacy: .public)")
        }
    }
    #endif

    // MARK: Live session

    func begin() async {
        guard phase == .consent || phase == .paused || phase == .review else { return }
        resolver = SpeakerResolver(doctorLanguage: doctorLanguage, patientLanguage: patientLanguage)
        error = nil; phase = .connecting
        do {
            let fresh = try await session.startConsultation(ConsultationSessionRequest(consent: true, referralID: record.id, doctorLanguage: doctorLanguage, patientLanguage: patientLanguage))
            try await connectScribe(fresh.scribe)
            let scribe = self.scribe
            let started = await audio.start { chunk in Task { await scribe.send(pcm: chunk) } }
            guard started else { throw CoreError.consentRequired }
            audio.gate.setPaused(false)
            if startedAt == nil { startedAt = Date() }
            phase = .live
            scheduleTokenRotation()
            watchMicrophone()
        } catch {
            teardown()
            phase = segments.isEmpty ? .consent : .paused
            self.error = (error as? CoreError) == .consentRequired
                ? "Microphone access is needed. Allow it in Settings, or continue the visit without translation."
                : Self.message(error)
        }
    }

    private func connectScribe(_ endpoint: RealtimeEndpoint) async throws {
        let stream = try await scribe.connect(endpoint: endpoint, doctorLanguage: doctorLanguage, patientLanguage: patientLanguage)
        tasks.append(Task { [weak self] in
            for await event in stream { self?.handle(event) }
        })
    }
    /// ElevenLabs tokens last 15 minutes; rotate before they expire.
    private func scheduleTokenRotation() {
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(13 * 60))
                guard !Task.isCancelled, let self, self.phase == .live || self.phase == .paused else { return }
                await self.rotateCredentials()
            }
        })
    }
    /// Samples the input level once a second. No buffers at all means the engine stalled (restart
    /// it); buffers that are all exact zeros mean the input itself is muted or not permitted.
    private func watchMicrophone() {
        micHealth = .ok; _ = audio.level.drain()
        tasks.append(Task { [weak self] in
            var quietSeconds = 0, stalledSeconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let window = self.audio.level.drain()
                self.inputLevel = window.peak
                guard self.phase == .live else { quietSeconds = 0; stalledSeconds = 0; continue }
                stalledSeconds = window.buffers == 0 ? stalledSeconds + 1 : 0
                quietSeconds = window.buffers > 0 && window.nonZero == 0 ? quietSeconds + 1 : 0
                let health: MicHealth = stalledSeconds >= 3 ? .stalled : quietSeconds >= 4 ? .silent : .ok
                if health != self.micHealth { consultationAudioLog.info("mic health: \(String(describing: health), privacy: .public)") }
                self.micHealth = health
                if stalledSeconds == 3 || stalledSeconds == 8 { self.audio.restartCapture() }
            }
        })
    }

    private func rotateCredentials() async {
        do {
            let fresh = try await session.startConsultation(ConsultationSessionRequest(consent: true, referralID: record.id, doctorLanguage: doctorLanguage, patientLanguage: patientLanguage))
            await scribe.commit()
            try await connectScribe(fresh.scribe)
        } catch { self.error = "Connection refresh failed. Translation may stop; you can end and review the session. (\(Self.message(error)))" }
    }

    private func handle(_ event: ScribeEvent) {
        #if DEBUG
        // Event kinds only: transcript text is patient data and is never logged.
        switch event {
        case .started: consultationAudioLog.info("scribe: session started")
        case .partial(let text, _): consultationAudioLog.debug("scribe: partial (\(text.count) chars)")
        case .committed(let text, let language):
            consultationAudioLog.info("scribe: committed (\(text.count) chars, \(language ?? "?", privacy: .public))")
            // Opt-in for synthetic test audio only; real consultations never log text.
            if ProcessInfo.processInfo.environment["EDGECARE_DEBUG_LOG_TEXT"] == "1" { consultationAudioLog.info("scribe text: \(text, privacy: .public)") }
        case .failed(let message): consultationAudioLog.error("scribe: failed \(message, privacy: .public)")
        case .closed: consultationAudioLog.error("scribe: closed")
        }
        #endif
        switch event {
        case .partial(let text, let language):
            partial = text
            audio.holdPlayback = phase == .live
            // Scribe only reports a partial's language once it is stable, so follow it live.
            if !sameLanguage, case .resolved(let speaker, _, _) = resolver.resolve(languageCode: language) { follow(speaker, language: language) }
        case .committed(let text, let language):
            partial = ""
            audio.holdPlayback = false
            let toggled = pendingCommitSpeaker ?? activeSpeaker
            pendingCommitSpeaker = nil
            if sameLanguage {
                append(text: text, speaker: toggled, source: patientLanguage, target: patientLanguage, overridden: false)
                return
            }
            var language = language
            if case .unclear = resolver.resolve(languageCode: language),
               let guess = TextLanguageGuess.guess(text, among: [resolver.doctorLanguage, resolver.patientLanguage]) {
                language = guess
            }
            switch resolver.resolve(languageCode: language) {
            case .resolved(let speaker, let source, let target):
                follow(speaker, language: language)
                append(text: text, speaker: speaker, source: source, target: target, overridden: false)
            case .unclear where language == nil:
                // Too short to tell ("yes", "ok"): the toggle says who is talking.
                guard case .resolved(let speaker, let source, let target) = resolver.direction(for: toggled) else { return }
                append(text: text, speaker: speaker, source: source, target: target, overridden: false)
            case .unclear: unclear.append(UnclearUtterance(text: text, language: language))
            }
        case .failed(let message): error = "Transcription problem: \(message)"
        case .closed:
            guard phase == .live || phase == .paused else { return }
            error = "Translation connection closed. Tap Resume to reconnect."
            teardown(); phase = .paused
        case .started: break
        }
    }
    private func append(text: String, speaker: ConsultationSpeaker, source: String, target: String, overridden: Bool) {
        let segment = ConsultationSegment(seq: nextSeq, speaker: speaker, sourceLanguage: source, targetLanguage: target, originalText: text, speakerOverridden: overridden)
        nextSeq += 1
        segments.append(segment)
        // Same language: the words are the record; nothing to translate or speak.
        if source == target { segments[segments.count - 1].translatedText = text; return }
        Task { await translate(seq: segment.seq) }
    }

    /// The clinician hands the floor to a participant. Speech in progress is finalised first so it
    /// stays with the previous speaker. In two-language visits detection can move it back.
    func setSpeaker(_ speaker: ConsultationSpeaker) {
        speakerSource = .manual
        guard speaker != activeSpeaker else { return }
        if !partial.isEmpty {
            pendingCommitSpeaker = activeSpeaker
            Task { await scribe.commit() }
        }
        activeSpeaker = speaker
    }
    /// Moves the toggle to the participant whose language was just detected.
    private func follow(_ speaker: ConsultationSpeaker, language: String?) {
        if let language { speakerSource = .detected(language: SpeakerResolver.normalize(language)) }
        activeSpeaker = speaker
    }
    private func translate(seq: Int, speak: Bool = true) async {
        guard let index = segments.firstIndex(where: { $0.seq == seq }) else { return }
        let segment = segments[index]
        translating.insert(seq); defer { translating.remove(seq) }
        do {
            let result = try await session.translateConsultation(ConsultationTranslateRequest(consent: true, text: segment.originalText, sourceLanguage: segment.sourceLanguage, targetLanguage: segment.targetLanguage, speaker: segment.speaker, synthesize: speak))
            guard let current = segments.firstIndex(where: { $0.seq == seq }), segments[current].sourceLanguage == segment.sourceLanguage else { return }
            segments[current].translatedText = result.translatedText
            if speak, phase == .live, let data = result.audio { audio.enqueue(data) }
        } catch { self.error = "Translation failed for one sentence. Ask the speaker to repeat. (\(Self.message(error)))" }
    }

    /// The clinician corrects who spoke; the sentence is re-translated in the other direction.
    func swapSpeaker(seq: Int) {
        guard let index = segments.firstIndex(where: { $0.seq == seq }) else { return }
        let next: ConsultationSpeaker = segments[index].speaker == .doctor ? .patient : .doctor
        if sameLanguage {
            segments[index].speaker = next; segments[index].speakerOverridden = true; return
        }
        guard case .resolved(let speaker, let source, let target) = resolver.direction(for: next) else { return }
        segments[index].speaker = speaker; segments[index].sourceLanguage = source; segments[index].targetLanguage = target
        segments[index].translatedText = ""; segments[index].speakerOverridden = true
        Task { await translate(seq: seq) }
    }
    func assign(_ utterance: UnclearUtterance, to speaker: ConsultationSpeaker) {
        unclear.removeAll { $0.id == utterance.id }
        guard case .resolved(let speaker, let source, let target) = resolver.direction(for: speaker) else { return }
        append(text: utterance.text, speaker: speaker, source: source, target: target, overridden: true)
    }
    func discard(_ utterance: UnclearUtterance) { unclear.removeAll { $0.id == utterance.id } }
    func replay(seq: Int) {
        guard phase == .live, let segment = segments.first(where: { $0.seq == seq }) else { return }
        Task {
            if let speech = try? await session.speakConsultation(ConsultationSpeakRequest(consent: true, text: segment.effectiveTranslation, language: segment.targetLanguage)), let data = speech.audio {
                audio.enqueue(data)
            }
        }
    }

    func pause() {
        guard phase == .live else { return }
        audio.gate.setPaused(true); audio.holdPlayback = false
        Task { await scribe.commit() }
        phase = .paused
    }
    func resume() async {
        guard phase == .paused else { return }
        // After a suspension or socket loss there is nothing to un-gate: reconnect with fresh tokens.
        if tasks.isEmpty { await begin(); return }
        audio.gate.setPaused(false); phase = .live
    }

    /// Backgrounding closes sockets and the microphone; the transcript stays in memory only.
    func suspend() {
        guard phase == .live || phase == .paused || phase == .connecting else { return }
        teardown(); phase = .paused
    }

    // MARK: Notes and confirmation

    func end() async {
        guard canEnd else { return }
        audio.gate.setPaused(true)
        await scribe.commit()
        phase = .drafting
        // Let the final committed segment arrive.
        try? await Task.sleep(for: .milliseconds(1500))
        teardown()
        while !translating.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        let endedAt = Date()
        let disputes = review?.disputedItems ?? []
        do {
            let draft = try await session.draftConsultationNotes(notesRequest())
            review = ConsultationReview(draft: draft, segments: segments, endedAt: endedAt, disputedItems: disputes)
            phase = .review
        } catch {
            self.error = Self.message(error)
            // Keep the transcript; the clinician can retry drafting.
            review = ConsultationReview(draft: ConsultationNotesDraft(), segments: segments, endedAt: endedAt, disputedItems: disputes)
            phase = .review
        }
    }
    private func notesRequest(edits: String? = nil) -> ConsultationNotesRequest {
        ConsultationNotesRequest(consent: true, doctorLanguage: doctorLanguage, patientLanguage: patientLanguage,
                                 transcript: review?.segments ?? segments, clinicianEdits: edits)
    }
    /// Re-runs drafting from the transcript after a provider failure (replaces the whole draft).
    func retryDraft() async {
        guard var review else { return }
        regenerating = true; defer { regenerating = false }
        do { review.applyRegenerated(try await session.draftConsultationNotes(notesRequest())); self.review = review; error = nil }
        catch { self.error = Self.message(error) }
    }
    /// Regenerates both summaries from the clinician's edits so the patient confirms current content.
    func regenerateSummaries() async {
        guard var review else { return }
        regenerating = true; defer { regenerating = false }
        let draft = review.draft.structured
        let edits = "Clinician-confirmed fields (take priority): " + ((try? String(data: JSONEncoder().encode(draft), encoding: .utf8)) ?? "")
            + "\nClinician summary: " + review.draft.clinicalSummary + "\nClinician meeting notes: " + review.draft.meetingNotes
        do {
            var regenerated = try await session.draftConsultationNotes(notesRequest(edits: edits))
            // The clinician's own wording of the English fields is kept verbatim.
            regenerated.structured = review.draft.structured
            review.applyRegenerated(regenerated)
            self.review = review; error = nil
        } catch { self.error = Self.message(error) }
    }
    func readSummaryAloud() async {
        guard let text = review?.draft.patientLanguageSummary, !text.isEmpty else { return }
        speaking = true; defer { speaking = false }
        do {
            let speech = try await session.speakConsultation(ConsultationSpeakRequest(consent: true, text: text, language: patientLanguage))
            if let data = speech.audio { audio.enqueue(data) } else { error = speech.speechError }
        } catch { self.error = Self.message(error) }
    }
    /// Patient said something is wrong: record it, clear confirmations, and reopen the live session.
    func patientDisputes(_ note: String) async {
        review?.dispute(note.isEmpty ? "Patient indicated the summary was not correct" : note)
        await begin()
    }
    func submit() async {
        guard let review, let startedAt, review.canSubmit else { return }
        phase = .submitting; error = nil
        do {
            let consultation = try review.record(consultationID: consultationID, referralID: record.id, startedAt: startedAt,
                                                 doctorLanguage: doctorLanguage, patientLanguage: patientLanguage)
            phase = .finished(try await session.submitConsultation(consultation))
        } catch {
            self.error = Self.message(error); phase = .review
        }
    }

    func teardown() {
        tasks.forEach { $0.cancel() }; tasks = []
        audio.stop()
        Task { [scribe] in await scribe.close() }
    }
    /// Clears all in-memory consultation content (nothing was persisted unless it was submitted).
    func discardAll() {
        teardown(); segments = []; unclear = []; review = nil; partial = ""
    }

    static func message(_ error: any Error) -> String {
        switch error as? CoreError {
        case .offline: return "This phone is offline. Consultations need a connection; the visit can continue without translation."
        case .providerUnavailable: return "Live translation is not configured on the server or is temporarily unavailable."
        case .unauthorized: return "This device needs the clinician access token to start a consultation."
        case .conflict: return "This consultation was already saved with different content. Review it in the CRM."
        case .some(let core): return core.userMessage
        case .none: return "The request could not complete. Check the connection and try again."
        }
    }
}
