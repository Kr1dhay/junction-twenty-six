import XCTest
@testable import EdgeCareCore

final class ConsultationTests: XCTestCase {
    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "consultation", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testFixtureRoundTripsThroughTheSharedWireFormat() throws {
        let data = try fixture()
        let record = try JSONDecoder().decode(ConsultationRecord.self, from: data)
        XCTAssertEqual(record.structured.recommendedSpecialty, "dermatology")
        XCTAssertEqual(record.transcript.count, 2)
        let encoded = try JSONEncoder().encode(record)
        // Compare as JSON objects: every key the server requires (including nulls) must survive.
        let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        let roundTripped = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
        XCTAssertEqual(original, roundTripped)
        let segment = try XCTUnwrap(roundTripped?["transcript"] as? [[String: Any]]).first
        XCTAssertTrue(segment?.keys.contains("correction") == true, "null correction must be encoded")
    }

    func testEmptySpecialtyIsEncodedAsNull() throws {
        var structured = ConsultationStructured(); structured.recommendedSpecialty = "  "
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(structured)) as? [String: Any]
        XCTAssertTrue(object?["recommended_specialty"] is NSNull)
    }

    func testSpeakerResolverUsesDetectedLanguageAndRejectsEverythingElse() {
        let resolver = SpeakerResolver(doctorLanguage: "en", patientLanguage: "so")
        XCTAssertEqual(resolver.resolve(languageCode: "som"), .resolved(speaker: .patient, source: "so", target: "en"))
        XCTAssertEqual(resolver.resolve(languageCode: "en-GB"), .resolved(speaker: .doctor, source: "en", target: "so"))
        XCTAssertEqual(resolver.resolve(languageCode: nil), .unclear)
        XCTAssertEqual(resolver.resolve(languageCode: ""), .unclear)
        XCTAssertEqual(resolver.resolve(languageCode: "fr"), .unclear)
        XCTAssertEqual(resolver.direction(for: .patient), .resolved(speaker: .patient, source: "so", target: "en"))
    }

    private func review() -> ConsultationReview {
        var draft = ConsultationNotesDraft(clinicalSummary: "Two months", patientLanguageSummary: "Laba bilood")
        draft.structured.presentingComplaint = "Skin mark"
        let segments = [ConsultationSegment(seq: 0, speaker: .patient, sourceLanguage: "so", targetLanguage: "en", originalText: "Laba bilood", translatedText: "Two months")]
        return ConsultationReview(draft: draft, segments: segments, endedAt: Date(timeIntervalSince1970: 1000))
    }

    func testBothConfirmationsAreRequiredAndAnyChangeClearsThem() throws {
        var review = review()
        XCTAssertFalse(review.canSubmit)
        try review.confirmPatient(at: Date(timeIntervalSince1970: 2000))
        XCTAssertFalse(review.canSubmit)
        review.confirmDoctor(at: Date(timeIntervalSince1970: 2001))
        XCTAssertTrue(review.canSubmit)

        // Flagging a sentence clears both confirmations.
        review.setFlag(seq: 0, flagged: true, correction: nil)
        XCTAssertNil(review.patientConfirmedAt); XCTAssertNil(review.doctorConfirmedAt)

        // A clinician edit also makes the patient summary stale until regenerated.
        try review.confirmPatient(); review.confirmDoctor()
        var edited = review.draft; edited.structured.plan = "Refer to dermatology"
        review.editByClinician(edited)
        XCTAssertFalse(review.canSubmit)
        XCTAssertThrowsError(try review.confirmPatient())
        review.applyRegenerated(edited)
        try review.confirmPatient(); review.confirmDoctor()
        XCTAssertTrue(review.canSubmit)

        // A correction is a factual change: summaries must be regenerated.
        review.setFlag(seq: 0, flagged: true, correction: "Two or three months")
        XCTAssertTrue(review.patientSummaryStale)
        XCTAssertEqual(review.segments[0].effectiveTranslation, "Two or three months")

        // A patient dispute is recorded and clears confirmations.
        review.applyRegenerated(review.draft)
        try review.confirmPatient(); review.confirmDoctor()
        review.dispute("Patient says it was three months")
        XCTAssertFalse(review.canSubmit)
        XCTAssertEqual(review.disputedItems, ["Patient says it was three months"])
    }

    func testRecordRequiresConfirmationAndStampsAfterTheSession() throws {
        var review = review()
        XCTAssertThrowsError(try review.record(consultationID: UUID().uuidString, referralID: UUID().uuidString, startedAt: Date(timeIntervalSince1970: 0), doctorLanguage: "en", patientLanguage: "so"))
        // A confirmation timestamp can never precede the end of the session.
        try review.confirmPatient(at: Date(timeIntervalSince1970: 10)); review.confirmDoctor(at: Date(timeIntervalSince1970: 10))
        let record = try review.record(consultationID: "AAAAAAAA-0000-4000-8000-000000000001", referralID: "BBBBBBBB-0000-4000-8000-000000000001", startedAt: Date(timeIntervalSince1970: 0), doctorLanguage: "en", patientLanguage: "so")
        XCTAssertEqual(record.consultationID, "aaaaaaaa-0000-4000-8000-000000000001")
        XCTAssertEqual(record.confirmation.patientConfirmedAt, record.endedAt)
        XCTAssertNil(record.recording.model)
        // Only the summary and key points reach the health record, never the conversation itself.
        XCTAssertFalse(review.segments.isEmpty)
        XCTAssertTrue(record.transcript.isEmpty)
        XCTAssertFalse(record.recording.transcriptAvailable)
    }

    func testScribeParserAttachesFinalLanguageAndFlushesOrphans() throws {
        var parser = ScribeEventParser()
        func send(_ json: String) -> [ScribeEvent] { parser.ingest(Data(json.utf8)) }
        XCTAssertEqual(send(#"{"message_type":"session_started"}"#), [.started])
        XCTAssertEqual(send(#"{"message_type":"partial_transcript","text":"Qiyaastii","language_code":null}"#), [.partial(text: "Qiyaastii", language: nil)])
        XCTAssertEqual(send(#"{"message_type":"partial_transcript","text":"Qiyaastii laba bilood","language_code":"so"}"#), [.partial(text: "Qiyaastii laba bilood", language: "so")])
        XCTAssertEqual(send(#"{"message_type":"committed_transcript","text":"Qiyaastii laba bilood."}"#), [])
        XCTAssertEqual(send(#"{"message_type":"committed_transcript_with_timestamps","text":"Qiyaastii laba bilood.","language_code":"som","words":[]}"#), [.committed(text: "Qiyaastii laba bilood.", language: "som")])
        // Without the timestamped message, the next segment releases the pending one.
        XCTAssertEqual(send(#"{"message_type":"committed_transcript","text":"Hello."}"#), [])
        XCTAssertEqual(send(#"{"message_type":"partial_transcript","text":"How","language_code":null}"#), [.committed(text: "Hello.", language: nil), .partial(text: "How", language: nil)])
        XCTAssertEqual(send(#"{"message_type":"auth_error","error":"expired"}"#), [.failed("expired")])
        XCTAssertEqual(parser.flush(), [])
    }

    func testWireStaysCompatibleWithBackendsThatStillExpectTheRemovedRecorder() throws {
        // Notes requests always carry the legacy fields empty: the summary comes from the transcript text.
        let segment = ConsultationSegment(seq: 0, speaker: .patient, sourceLanguage: "fi", targetLanguage: "fi", originalText: "Päätä särkee.", translatedText: "Päätä särkee.")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConsultationNotesRequest(consent: true, doctorLanguage: "fi", patientLanguage: "fi", transcript: [segment]))) as? [String: Any]
        XCTAssertTrue(body?["live_transcript"] is NSNull)
        XCTAssertEqual(body?["live_key_points"] as? [String], [])
        XCTAssertNil(body?["clinician_edits"])
        // Session credentials decode whether or not an older backend still returns a recorder token.
        for json in [#"{"scribe":{"token":"t","model":"scribe_v3_live","url":"wss://x"},"expires_at":"2026-11-14T10:00:00Z"}"#,
                     #"{"scribe":{"token":"t","model":"scribe_v3_live","url":"wss://x"},"live":null,"expires_at":"2026-11-14T10:00:00Z"}"#] {
            XCTAssertEqual(try JSONDecoder().decode(ConsultationSessionCredentials.self, from: Data(json.utf8)).scribe.token, "t")
        }
    }

    func testScribeURLRedetectsLanguagePerUtteranceInTwoLanguageVisits() throws {
        func items(_ model: String, _ doctor: String, _ patient: String) throws -> [String: String] {
            let url = try RealtimeScribeClient.url(endpoint: RealtimeEndpoint(token: "t", model: model, url: "wss://api.elevenlabs.io/v1/speech-to-text/realtime"), doctorLanguage: doctor, patientLanguage: patient)
            return Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        // Language hints make detection sticky, so two-language visits send none.
        let multi = try items("scribe_v3_live", "en", "som")
        XCTAssertEqual(multi["multilang_mode"], "true"); XCTAssertNil(multi["language_code"]); XCTAssertNil(multi["secondary_languages"])
        XCTAssertEqual(multi["audio_format"], "pcm_16000"); XCTAssertEqual(multi["commit_strategy"], "vad")
        XCTAssertEqual(multi["include_language_detection"], "true"); XCTAssertEqual(multi["token"], "t")
        // Other models reject multilang_mode.
        let older = try items("scribe_v2_realtime", "en", "fi")
        XCTAssertNil(older["multilang_mode"]); XCTAssertNil(older["language_code"])
        // Same language: nothing to tell apart, so fix it for accuracy.
        let same = try items("scribe_v3_live", "fi", "fin")
        XCTAssertEqual(same["language_code"], "fi"); XCTAssertNil(same["multilang_mode"])
        XCTAssertThrowsError(try RealtimeScribeClient.url(endpoint: RealtimeEndpoint(token: "t", model: "m", url: "http://insecure"), doctorLanguage: "en", patientLanguage: "so"))
    }

}

@MainActor final class ConsultationSubmissionTests: XCTestCase {
    private let key = Data(repeating: 23, count: 32)
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func record() throws -> ConsultationRecord {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "consultation", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(ConsultationRecord.self, from: Data(contentsOf: url))
    }
    private func session(_ directory: URL, api: any ConsultationAPI, online: Bool) throws -> NativeSession {
        let wallet = try ReferralWallet(storeURL: directory.appendingPathComponent("wallet.enc"), key: key)
        let outbox = try ReferralOutbox(storeURL: directory.appendingPathComponent("outbox.enc"), key: key)
        let consultations = try ConsultationOutbox(storeURL: directory.appendingPathComponent("consultations.enc"), key: key)
        return NativeSession(configuration: .connectedDemo, wallet: wallet, outbox: outbox, chain: try MockChainClient(storeURL: directory.appendingPathComponent("chain.json")), api: MockReferralAPI(),
                             online: online, consultationAPI: api, consultationOutbox: consultations)
    }

    func testConfirmedConsultationQueuesOfflineAndUploadsOnSync() async throws {
        let directory = try folder()
        let api = RecordingConsultationAPI()
        let offline = try session(directory, api: api, online: false)
        let canConsultOffline = await offline.canConsult
        XCTAssertFalse(canConsultOffline)
        let outcome = try await offline.submitConsultation(record())
        XCTAssertEqual(outcome, .queued)
        let submittedOffline = await api.submitted.count
        XCTAssertEqual(submittedOffline, 0)
        // The queue survives a restart: it is encrypted on disk, not held in memory.
        let raw = try Data(contentsOf: directory.appendingPathComponent("consultations.enc"))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("dermatology"))
        let restarted = try session(directory, api: api, online: true)
        let pending = await restarted.pendingConsultations().count
        XCTAssertEqual(pending, 1)
        let report = try await restarted.sync()
        XCTAssertEqual(report.uploaded, 1)
        let submitted = await api.submitted.count
        XCTAssertEqual(submitted, 1)
        let remaining = await restarted.pendingConsultations().count
        XCTAssertEqual(remaining, 0)
    }

    func testTransportFailureKeepsTheRecordQueued() async throws {
        let directory = try folder()
        let api = RecordingConsultationAPI(failure: URLError(.notConnectedToInternet))
        let online = try session(directory, api: api, online: true)
        let outcome = try await online.submitConsultation(record())
        XCTAssertEqual(outcome, .queued)
        let pending = await online.pendingConsultations().count
        XCTAssertEqual(pending, 1)
    }

    func testLocalModeNeverContactsConsultationServices() async throws {
        let directory = try folder()
        let local = try session(directory, api: MockConsultationAPI(), online: true)
        let canConsult = await local.canConsult
        XCTAssertFalse(canConsult)
        do { _ = try await local.startConsultation(ConsultationSessionRequest(consent: true, referralID: UUID().uuidString, doctorLanguage: "en", patientLanguage: "so")); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? CoreError, .providerUnavailable) }
    }
}

private actor RecordingConsultationAPI: ConsultationAPI {
    private(set) var submitted: [ConsultationRecord] = []
    private let failure: (any Error)?
    init(failure: (any Error)? = nil) { self.failure = failure }
    func startSession(_ request: ConsultationSessionRequest) async throws -> ConsultationSessionCredentials { throw CoreError.notConfigured }
    func translate(_ request: ConsultationTranslateRequest) async throws -> ConsultationTranslation { throw CoreError.notConfigured }
    func draftNotes(_ request: ConsultationNotesRequest) async throws -> ConsultationNotesDraft { throw CoreError.notConfigured }
    func speak(_ request: ConsultationSpeakRequest) async throws -> ConsultationSpeech { throw CoreError.notConfigured }
    func submit(_ record: ConsultationRecord) async throws {
        if let failure { throw failure }
        submitted.append(record)
    }
}
