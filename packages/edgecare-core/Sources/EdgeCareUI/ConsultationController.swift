import Foundation
import Observation
import os
import EdgeCareCore

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
    private(set) var keyPoints: [String] = []
    private(set) var translating: Set<Int> = []
    private(set) var recordingStatus = "Not started"
    private(set) var recordingAvailable = false
    private(set) var recordingModel: String?
    var review: ConsultationReview?
    var error: String?
    private(set) var regenerating = false
    private(set) var speaking = false
    /// Same-language visits cannot attribute speech by language, so the clinician sets who is talking.
    private(set) var activeSpeaker: ConsultationSpeaker = .patient
    /// Speech in progress when the toggle flips still belongs to the previous speaker.
    private var pendingCommitSpeaker: ConsultationSpeaker?

    private let consultationID = UUID().uuidString.lowercased()
    private var startedAt: Date?
    private var heard: [String] = []
    private var resolver: SpeakerResolver
    private let audio = ConsultationAudioEngine()
    private let scribe = RealtimeScribeClient()
    private let recorder = GeminiLiveRecorder()
    private var credentials: ConsultationSessionCredentials?
    private var resumptionHandle: String?
    private var tasks: [Task<Void, Never>] = []
    private var nextSeq = 0
    private var recordingEverWorked = false
    private var recorderReconnects = 0

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

    // MARK: Live session

    func begin() async {
        guard phase == .consent || phase == .paused || phase == .review else { return }
        resolver = SpeakerResolver(doctorLanguage: doctorLanguage, patientLanguage: patientLanguage)
        error = nil; phase = .connecting
        do {
            let fresh = try await session.startConsultation(ConsultationSessionRequest(consent: true, referralID: record.id, doctorLanguage: doctorLanguage, patientLanguage: patientLanguage))
            credentials = fresh; recorderReconnects = 0
            try await connectScribe(fresh.scribe)
            await connectRecorder()
            let scribe = self.scribe, recorder = self.recorder
            let started = await audio.start { chunk in
                Task { await scribe.send(pcm: chunk) }
                Task { await recorder.send(pcm: chunk) }
            }
            guard started else { throw CoreError.consentRequired }
            audio.gate.setPaused(false)
            if startedAt == nil { startedAt = Date() }
            phase = .live
            scheduleTokenRotation()
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
    private func connectRecorder() async {
        guard let live = credentials?.live else {
            recordingStatus = "Not configured · translation transcript only"; recordingAvailable = recordingEverWorked; return
        }
        recordingModel = live.model
        do {
            let stream = try await recorder.connect(endpoint: live, resumptionHandle: resumptionHandle)
            recordingStatus = "Connecting…"
            tasks.append(Task { [weak self] in
                for await event in stream { self?.handle(event) }
            })
        } catch { recordingStatus = "Unavailable · translation transcript only" }
    }
    /// ElevenLabs tokens last 15 minutes; rotate both credentials before they expire.
    private func scheduleTokenRotation() {
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(13 * 60))
                guard !Task.isCancelled, let self, self.phase == .live || self.phase == .paused else { return }
                await self.rotateCredentials()
            }
        })
    }
    private func rotateCredentials() async {
        do {
            let fresh = try await session.startConsultation(ConsultationSessionRequest(consent: true, referralID: record.id, doctorLanguage: doctorLanguage, patientLanguage: patientLanguage))
            credentials = fresh; recorderReconnects = 0
            await scribe.commit()
            try await connectScribe(fresh.scribe)
            // Gemini resumes the same recording with the handle under the new token.
            await connectRecorder()
        } catch { self.error = "Connection refresh failed. Translation may stop; you can end and review the session. (\(Self.message(error)))" }
    }

    private func handle(_ event: ScribeEvent) {
        #if DEBUG
        // Event kinds only: transcript text is patient data and is never logged.
        switch event {
        case .started: consultationAudioLog.info("scribe: session started")
        case .partial(let text, _): consultationAudioLog.debug("scribe: partial (\(text.count) chars)")
        case .committed(let text, let language): consultationAudioLog.info("scribe: committed (\(text.count) chars, \(language ?? "?", privacy: .public))")
        case .failed(let message): consultationAudioLog.error("scribe: failed \(message, privacy: .public)")
        case .closed: consultationAudioLog.error("scribe: closed")
        }
        #endif
        switch event {
        case .partial(let text, _): partial = text
        case .committed(let text, let language):
            partial = ""
            if sameLanguage {
                let speaker = pendingCommitSpeaker ?? activeSpeaker
                pendingCommitSpeaker = nil
                append(text: text, speaker: speaker, source: patientLanguage, target: patientLanguage, overridden: false)
                return
            }
            switch resolver.resolve(languageCode: language) {
            case .resolved(let speaker, let source, let target): append(text: text, speaker: speaker, source: source, target: target, overridden: false)
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
    private func handle(_ event: LiveRecorderEvent) {
        #if DEBUG
        switch event {
        case .failed(let message): consultationAudioLog.error("recorder: failed \(message, privacy: .public)")
        case .closed: consultationAudioLog.error("recorder: closed")
        case .ready: consultationAudioLog.info("recorder: ready")
        case .goAway: consultationAudioLog.info("recorder: goAway")
        default: break
        }
        #endif
        switch event {
        case .ready: recordingStatus = "Recording with \(recordingModel ?? "Gemini Live")"; recordingAvailable = true; recordingEverWorked = true
        case .heard(let text): heard.append(text)
        case .keyPoints(let points): keyPoints.append(contentsOf: points)
        case .resumptionHandle(let handle): resumptionHandle = handle
        case .goAway: reconnectRecorder()
        case .failed(let message): recordingStatus = "Recording problem: \(message)"
        case .closed: if recordingAvailable { reconnectRecorder() }
        }
    }

    /// Resumes the same Gemini recording via its handle; capped so an expired token cannot loop.
    private func reconnectRecorder() {
        guard phase == .live || phase == .paused, recorderReconnects < 3 else {
            recordingStatus = "Recording stopped · translation transcript continues"; recordingAvailable = false; return
        }
        recorderReconnects += 1; recordingStatus = "Reconnecting recorder…"
        Task { [weak self] in await self?.connectRecorder() }
    }
    private func append(text: String, speaker: ConsultationSpeaker, source: String, target: String, overridden: Bool) {
        let segment = ConsultationSegment(seq: nextSeq, speaker: speaker, sourceLanguage: source, targetLanguage: target, originalText: text, speakerOverridden: overridden)
        nextSeq += 1
        segments.append(segment)
        // Same language: the words are the record; nothing to translate or speak.
        if source == target { segments[segments.count - 1].translatedText = text; return }
        Task { await translate(seq: segment.seq) }
    }

    /// Hands the floor to a participant (same-language visits only).
    func setSpeaker(_ speaker: ConsultationSpeaker) {
        guard sameLanguage, speaker != activeSpeaker else { return }
        if !partial.isEmpty {
            pendingCommitSpeaker = activeSpeaker
            Task { await scribe.commit() }
        }
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
        audio.gate.setPaused(true)
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
        await scribe.commit(); await recorder.endAudio()
        phase = .drafting
        // Let the final committed segment and recorder turn arrive.
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
                                 transcript: review?.segments ?? segments,
                                 liveTranscript: heard.isEmpty ? nil : heard.joined(separator: " "),
                                 liveKeyPoints: keyPoints, clinicianEdits: edits)
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
                                                 doctorLanguage: doctorLanguage, patientLanguage: patientLanguage,
                                                 recordingModel: recordingModel, recordingAvailable: recordingEverWorked)
            phase = .finished(try await session.submitConsultation(consultation))
        } catch {
            self.error = Self.message(error); phase = .review
        }
    }

    func teardown() {
        tasks.forEach { $0.cancel() }; tasks = []
        audio.stop()
        Task { [scribe, recorder] in await scribe.close(); await recorder.close() }
    }
    /// Clears all in-memory consultation content (nothing was persisted unless it was submitted).
    func discardAll() {
        teardown(); segments = []; unclear = []; keyPoints = []; heard = []; review = nil; partial = ""
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
