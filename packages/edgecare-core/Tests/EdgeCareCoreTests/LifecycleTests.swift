import CryptoKit
import XCTest
@testable import EdgeCareCore

@MainActor final class LifecycleTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private let key = Data(repeating: 17, count: 32)
    private func draft() async throws -> EnrollmentDraft {
        let guidance = try await OnDeviceTriageEngine().guidance(for: "changing mole", language: "en")
        return EnrollmentDraft(source: .patientApp, language: "en", concern: "PRIVATE concern 90210", guidance: guidance,
            letterText: "PRIVATE letter 842", lesionPresent: true, answers: ["persistent_or_changing": "yes"])
    }
    private func record() async throws -> ReferralRecord {
        try EnrollmentService().enroll(draft: await draft(), strokes: DemoData.signatureStrokes(),
            passcode: "0123", confirmation: "0123")
    }
    private func session(directory: URL, chain: any ChainClient, api: any ReferralAPI, online: Bool = true) throws -> NativeSession {
        let wallet = try ReferralWallet(storeURL: directory.appendingPathComponent("wallet.enc"), key: key)
        let outbox = try ReferralOutbox(storeURL: directory.appendingPathComponent("outbox.enc"), key: key)
        return NativeSession(configuration: .connectedDemo, wallet: wallet, outbox: outbox, chain: chain, api: api, online: online)
    }
    func testEnrollmentRequiresDoubleEntryAndEncryptsFullDetail() async throws {
        let draft = try await draft()
        XCTAssertThrowsError(try EnrollmentService().enroll(draft: draft, strokes: DemoData.signatureStrokes(), passcode: "0123", confirmation: "1234")) { error in
            XCTAssertEqual(error as? CoreError, .passcodesDoNotMatch)
        }
        let record = try await record()
        XCTAssertEqual(record.status, .open)
        XCTAssertEqual(record.source, .patientApp)
        XCTAssertEqual(record.referralID, record.referralID.lowercased())
        XCTAssertFalse(record.freeTextSummary.contains("PRIVATE"))
        XCTAssertNil(record.letterScan.extractedText)
        let salt = try XCTUnwrap(Data(base64Encoded: record.salt))
        let detail = try CommitmentCrypto.decrypt(XCTUnwrap(Data(base64Encoded: record.triageDetailEncrypted)), passcode: "0123", salt: salt)
        XCTAssertTrue(String(decoding: detail, as: UTF8.self).contains("PRIVATE concern 90210"))
        XCTAssertTrue(String(decoding: detail, as: UTF8.self).contains("PRIVATE letter 842"))
        XCTAssertThrowsError(try CommitmentCrypto.decrypt(XCTUnwrap(Data(base64Encoded: record.triageDetailEncrypted)), passcode: "0124", salt: salt))
        _ = try VerificationService.authenticate(record: record, passcode: "0123", strokes: DemoData.signatureStrokes())
    }
    func testWalletEncryptsEveryFieldAndSurvivesReopen() async throws {
        let directory = try folder(), record = try await record()
        let url = directory.appendingPathComponent("wallet.enc")
        let wallet = try ReferralWallet(storeURL: url, key: key)
        try await wallet.store(record, state: .pendingEnrollment)
        let ciphertext = try Data(contentsOf: url)
        XCTAssertNil(ciphertext.range(of: Data(record.freeTextSummary.utf8)))
        XCTAssertNil(ciphertext.range(of: Data(record.id.utf8)))
        let reopened = try ReferralWallet(storeURL: url, key: key)
        let records = await reopened.records()
        XCTAssertEqual(records, [record])
        XCTAssertThrowsError(try ReferralWallet(storeURL: url, key: Data(repeating: 18, count: 32)))
        try await reopened.remove(id: record.id)
        let empty = try ReferralWallet(storeURL: url, key: key)
        let remaining = await empty.records()
        XCTAssertTrue(remaining.isEmpty)
    }
    func testOfflineEnrollmentQueuesThenSyncsOnReconnect() async throws {
        let directory = try folder()
        let chain = try MockChainClient(storeURL: directory.appendingPathComponent("registry.json"))
        let api = MockReferralAPI()
        let app = try session(directory: directory, chain: chain, api: api, online: false)
        let record = try await app.enroll(draft: draft(), strokes: DemoData.signatureStrokes(), passcode: "1234", confirmation: "1234")
        let before = await chain.read(referralID: record.id)
        XCTAssertNil(before)
        let queued = await app.outbox.pending()
        XCTAssertEqual(queued.count, 1)
        let restored = try session(directory: directory, chain: chain, api: api, online: false)
        let restoredEntries = await restored.walletEntries()
        XCTAssertEqual(restoredEntries.first?.state, .pendingEnrollment)
        await restored.setOnline(true)
        let fetched = try await api.fetchVerificationEnvelope(id: record.id)
        XCTAssertEqual(fetched, record)
        let entries = await restored.walletEntries()
        XCTAssertEqual(entries.first?.state, .available)
        let pending = await restored.outbox.pending()
        XCTAssertTrue(pending.isEmpty)
    }
    func testOfflineVerificationIsProvisionalAndRejectsLocalReplay() async throws {
        let directory = try folder(), record = try await record()
        let chain = try MockChainClient(storeURL: directory.appendingPathComponent("registry.json"))
        try await chain.create(referralID: record.id, hash: record.commitmentHash)
        let api = MockReferralAPI(records: [record])
        let app = try session(directory: directory, chain: chain, api: api)
        _ = try await app.cacheReferral(id: record.id)
        await app.setOnline(false)
        let verification = try await app.verify(record: record, passcode: "0123", strokes: DemoData.signatureStrokes())
        XCTAssertEqual(verification.referralID, record.id)
        let untouched = await chain.read(referralID: record.id)
        XCTAssertEqual(untouched?.spent, false, "Verification must not consume the referral")
        let outcome = try await app.markUsed(record: record, verification: verification)
        XCTAssertEqual(outcome.settlement, .provisional)
        let account = await chain.read(referralID: record.id)
        XCTAssertEqual(account?.spent, false)
        do { _ = try await app.markUsed(record: record, verification: verification); XCTFail("Local replay must fail") }
        catch { XCTAssertEqual(error as? CoreError, .alreadySpent) }
        // The patient can still be authenticated for a new visit.
        let reverified = try await app.verify(record: record, passcode: "0123", strokes: DemoData.signatureStrokes())
        XCTAssertEqual(reverified.referralID, record.id)
        let reopened = try session(directory: directory, chain: chain, api: api)
        let report = try await reopened.sync()
        XCTAssertEqual(report.confirmedSpends, 1)
        let entries = await reopened.walletEntries()
        XCTAssertEqual(entries.first?.state, .spent)
        let after = await chain.read(referralID: record.id)
        XCTAssertEqual(after?.spent, true)
    }
    func testUsedReferralCanBeReverifiedForANewVisit() async throws {
        let directory = try folder(), record = try await record()
        let chain = try MockChainClient(storeURL: directory.appendingPathComponent("registry.json"))
        try await chain.create(referralID: record.id, hash: record.commitmentHash)
        let api = MockReferralAPI(records: [record])
        let app = try session(directory: directory, chain: chain, api: api)
        _ = try await app.cacheReferral(id: record.id)
        let first = try await app.verify(record: record, passcode: "0123", strokes: DemoData.signatureStrokes())
        _ = try await app.markUsed(record: record, verification: first)
        let entries = await app.walletEntries()
        XCTAssertEqual(entries.first?.state, .spent)

        // Relaunching drops in-memory verification, so the patient authenticates again.
        let reopened = try session(directory: directory, chain: chain, api: api)
        let second = try await reopened.verify(record: record, passcode: "0123", strokes: DemoData.signatureStrokes())
        XCTAssertEqual(second.referralID, record.id)
        do { _ = try await reopened.markUsed(record: record, verification: second); XCTFail("A used referral cannot be consumed twice") }
        catch { XCTAssertEqual(error as? CoreError, .alreadySpent) }
    }
    func testFirstSharedSpendWinsAgainstQueuedOfflineSpend() async throws {
        let directory = try folder(), record = try await record()
        let chain = try MockChainClient(storeURL: directory.appendingPathComponent("registry.json"))
        try await chain.create(referralID: record.id, hash: record.commitmentHash)
        let api = MockReferralAPI(records: [record])
        let app = try session(directory: directory, chain: chain, api: api)
        _ = try await app.cacheReferral(id: record.id)
        await app.setOnline(false)
        let verification = try await app.verify(record: record, passcode: "0123", strokes: DemoData.signatureStrokes())
        _ = try await app.markUsed(record: record, verification: verification)
        // A different doctor's operation reaches the shared registry first.
        try await chain.spend(referralID: record.id, hash: record.commitmentHash, operationID: UUID().uuidString.lowercased())
        let reopened = try session(directory: directory, chain: chain, api: api)
        let refreshedBeforeSettlement = try await reopened.refreshWallet()
        XCTAssertEqual(refreshedBeforeSettlement.first?.state, .provisionalSpend)
        let stillPending = await reopened.outbox.pendingSpends()
        XCTAssertEqual(stillPending.count, 1)
        let report = try await reopened.sync()
        XCTAssertEqual(report.conflicts, [record.id])
        let entries = await reopened.walletEntries()
        XCTAssertEqual(entries.first?.state, .conflict)
        let pending = await reopened.outbox.pendingSpends()
        XCTAssertTrue(pending.isEmpty)
    }
    func testLostSpendResponseReusesDurableOperationID() async throws {
        let directory = try folder(), record = try await record()
        let registry = try MockChainClient(storeURL: directory.appendingPathComponent("registry.json"))
        try await registry.create(referralID: record.id, hash: record.commitmentHash)
        let chain = LoseFirstSpendResponse(registry: registry)
        let api = MockReferralAPI(records: [record])
        let app = try session(directory: directory, chain: chain, api: api)
        _ = try await app.cacheReferral(id: record.id)
        let verification = try await app.verify(record: record, passcode: "0123", strokes: DemoData.signatureStrokes())
        let outcome = try await app.markUsed(record: record, verification: verification)
        XCTAssertEqual(outcome.settlement, .provisional)
        let pending = await app.outbox.pendingSpends()
        XCTAssertEqual(pending.count, 1)
        let reopened = try session(directory: directory, chain: chain, api: api)
        let restored = await reopened.outbox.pendingSpends()
        XCTAssertEqual(restored.first?.operationID, pending.first?.operationID)
        let report = try await reopened.sync()
        XCTAssertEqual(report.confirmedSpends, 1)
        XCTAssertTrue(report.conflicts.isEmpty)
    }
    func testOfflineUncachedCommitmentCannotBeInvented() async throws {
        let directory = try folder(), record = try await record()
        let chain = try MockChainClient(storeURL: directory.appendingPathComponent("registry.json"))
        let app = try session(directory: directory, chain: chain, api: MockReferralAPI(), online: false)
        try await app.wallet.store(record)
        // Identity verification is local and succeeds; consumption needs a cached commitment.
        let verification = try await app.verify(record: record, passcode: "0123", strokes: DemoData.signatureStrokes())
        do { _ = try await app.markUsed(record: record, verification: verification); XCTFail("No account cached") }
        catch { XCTAssertEqual(error as? CoreError, .noCachedCommitment) }
        let pending = await app.outbox.pendingSpends()
        XCTAssertTrue(pending.isEmpty)
    }
    func testMockReceiptPersistsAndOnlySameOperationMayRetry() async throws {
        let url = try folder().appendingPathComponent("registry.json"), record = try await record()
        let chain = try MockChainClient(storeURL: url)
        let operation = UUID().uuidString.lowercased()
        try await chain.create(referralID: record.id, hash: record.commitmentHash)
        try await chain.spend(referralID: record.id, hash: record.commitmentHash, operationID: operation)
        let reopened = try MockChainClient(storeURL: url)
        try await reopened.spend(referralID: record.id, hash: record.commitmentHash, operationID: operation)
        try await reopened.create(referralID: record.id, hash: record.commitmentHash)
        do { try await reopened.spend(referralID: record.id, hash: record.commitmentHash, operationID: UUID().uuidString.lowercased()); XCTFail("New operation must fail") }
        catch { XCTAssertEqual(error as? CoreError, .alreadySpent) }
    }
    func testFiveLanguageScriptAndExplicitEmergencyAnswer() async throws {
        for language in SupportedLanguage.allCases {
            let guidance = try await OnDeviceTriageEngine().guidance(for: "screening letter [urgent_now=no]", language: language.rawValue)
            XCTAssertFalse(guidance.message.isEmpty)
            XCTAssertEqual(guidance.followUpQuestions.count, 4)
            XCTAssertFalse(guidance.requiresEmergencyHelp)
            XCTAssertTrue(guidance.label.contains("scripted"))
            XCTAssertFalse(language.noRecoveryWarning.isEmpty)
            let urgent = try await OnDeviceTriageEngine().guidance(for: "concern [urgent_now=yes]", language: language.rawValue)
            XCTAssertTrue(urgent.requiresEmergencyHelp)
            XCTAssertTrue(urgent.message.contains("112"))
        }
    }
    func testDemoTransportAndUnconsentedGeminiFailClosed() async throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1"))
        let chain = HTTPDemoChainClient(baseURL: url, configuration: .demo)
        do { _ = try await chain.read(referralID: "00000000-0000-4000-8000-000000000001"); XCTFail("Demo mode must reject HTTP before transport") }
        catch { XCTAssertEqual(error as? CoreError, .invalidConfiguration) }
        let gemini = GeminiTriageEngine(apiKey: "synthetic-key", configuration: .connectedDemo)
        do { _ = try await gemini.guidance(for: "private", language: "en"); XCTFail("Consent required") }
        catch { XCTAssertEqual(error as? CoreError, .consentRequired) }
    }

    func testEnglishProfilePersistsInsideEncryptedEnrollment() async throws {
        let local = try await draft()
        let profile = ClinicalProfile(concernEnglish: "Changing skin mark", symptomsEnglish: ["skin change"],
            durationEnglish: "More than two weeks", additionalContextEnglish: "Clinician assessment requested")
        let translated = EnrollmentDraft(source: .kiosk, language: "ar", concern: "تغيّر في الجلد", guidance: local.guidance,
            clinicalProfile: profile)
        let record = try EnrollmentService().enroll(draft: translated, strokes: DemoData.signatureStrokes(), passcode: "1234", confirmation: "1234")
        XCTAssertEqual(record.language, "ar")
        XCTAssertTrue(record.freeTextSummary.contains("Changing skin mark"))
        XCTAssertFalse(record.freeTextSummary.contains("تغيّر"))
        let detail = try CommitmentCrypto.decrypt(XCTUnwrap(Data(base64Encoded: record.triageDetailEncrypted)), passcode: "1234", salt: XCTUnwrap(Data(base64Encoded: record.salt)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: detail) as? [String: Any])
        let saved = try XCTUnwrap(object["clinicalProfile"] as? [String: Any])
        XCTAssertEqual(saved["concern_english"] as? String, "Changing skin mark")
    }
    func testVoiceAndNormalizationAreUnavailableWithoutConsentOrConnectivity() async throws {
        let directory = try folder()
        let chain = try MockChainClient(storeURL: directory.appendingPathComponent("registry.json"))
        let app = try session(directory: directory, chain: chain, api: MockReferralAPI(), online: false)
        do { _ = try await app.voiceTurn(audio: Data([1, 2, 3]), consent: true); XCTFail("Offline voice must never upload") }
        catch { XCTAssertEqual(error as? CoreError, .offline) }
        await app.setOnline(true)
        do { _ = try await app.voiceTurn(text: "Hello", consent: false); XCTFail("Voice requires explicit consent") }
        catch { XCTAssertEqual(error as? CoreError, .consentRequired) }
        do { _ = try await app.normalizeProfile(text: "Hello", consent: true); XCTFail("No configured voice client") }
        catch { XCTAssertEqual(error as? CoreError, .providerUnavailable) }
        let response = Data("""
        {"transcript":"Hei","detected_language":"fi","reply":"Miten voin auttaa?","profile":{"concern_english":"Health concern","symptoms_english":[],"duration_english":"","additional_context_english":""},"audio_base64":null,"audio_mime_type":null,"speech_available":false,"speech_error":"Not configured"}
        """.utf8)
        let decoded = try JSONDecoder().decode(VoiceTurnResponse.self, from: response)
        XCTAssertEqual(decoded.detectedLanguage, "fi")
        XCTAssertFalse(decoded.speechAvailable)
        XCTAssertNil(decoded.audio)
    }
    func testPatientWalletRefreshReflectsExternalSpendWithoutFetchingEnvelope() async throws {
        let directory = try folder(), record = try await record()
        let chain = try MockChainClient(storeURL: directory.appendingPathComponent("registry.json"))
        try await chain.create(referralID: record.id, hash: record.commitmentHash)
        let api = NoEnvelopeAPI()
        let patient = try session(directory: directory, chain: chain, api: api, online: false)
        let initialAccount = await chain.read(referralID: record.id)
        try await patient.wallet.store(record, account: initialAccount)
        try await chain.spend(referralID: record.id)
        let offlineEntries = try await patient.refreshWallet()
        XCTAssertEqual(offlineEntries.first?.state, .available)
        XCTAssertEqual(offlineEntries.first?.cachedAccount?.spent, false)
        // Reopen online without setOnline's automatic sync so refresh alone is exercised.
        let connectedPatient = try session(directory: directory, chain: chain, api: api)
        let refreshed = try await connectedPatient.refreshWallet()
        XCTAssertEqual(refreshed.first?.state, .spent)
        XCTAssertEqual(refreshed.first?.cachedAccount?.spent, true)
        let requests = await api.requestCount
        XCTAssertEqual(requests, 0, "Wallet reconciliation must not request clinician envelopes")
        let persisted = try session(directory: directory, chain: chain, api: api, online: false)
        let persistedEntries = await persisted.walletEntries()
        XCTAssertEqual(persistedEntries.first?.state, .spent)
    }
    func testCrashBetweenWalletAndOutboxEnrollmentIsRecovered() async throws {
        let directory = try folder(), record = try await record()
        let chain = try MockChainClient(storeURL: directory.appendingPathComponent("registry.json"))
        let app = try session(directory: directory, chain: chain, api: MockReferralAPI())
        try await app.wallet.store(record, state: .pendingEnrollment)
        let report = try await app.sync()
        XCTAssertEqual(report.uploaded, 1)
        let entries = await app.walletEntries()
        XCTAssertEqual(entries.first?.state, .available)
    }
}

private actor LoseFirstSpendResponse: ChainClient {
    let registry: MockChainClient
    var lose = true
    init(registry: MockChainClient) { self.registry = registry }
    func create(referralID: String, hash: String) async throws { try await registry.create(referralID: referralID, hash: hash) }
    func read(referralID: String) async throws -> CommitmentAccount? { await registry.read(referralID: referralID) }
    func spend(referralID: String) async throws { try await registry.spend(referralID: referralID) }
    func spend(referralID: String, hash: String, operationID: String) async throws {
        try await registry.spend(referralID: referralID, hash: hash, operationID: operationID)
        if lose { lose = false; throw URLError(.networkConnectionLost) }
    }
}

private actor NoEnvelopeAPI: ReferralAPI {
    private(set) var requestCount = 0
    func submit(_ record: ReferralRecord) throws { requestCount += 1; throw CoreError.notConfigured }
    func fetchVerificationEnvelope(id: String) throws -> ReferralRecord { requestCount += 1; throw CoreError.notConfigured }
    func list() throws -> [ReferralRecord] { requestCount += 1; throw CoreError.notConfigured }
}
