import XCTest
@testable import EdgeCareCore

@MainActor final class PatientProfileTests: XCTestCase {
    private let key = Data(repeating: 43, count: 32)
    private func folder() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private func record(code: String = "0123", now: Date = Date()) throws -> ReferralRecord {
        try EnrollmentService().enroll(draft: EnrollmentDraft(source: .patientApp, language: "en", concern: "Synthetic concern",
            guidance: TriageGuidance(message: "Review requested")), strokes: DemoData.signatureStrokes(), passcode: code,
            confirmation: code, now: now)
    }
    private func session(_ path: URL, api: any ReferralAPI, online: Bool = true) throws -> NativeSession {
        NativeSession(configuration: .connectedDemo,
            wallet: try ReferralWallet(storeURL: path.appendingPathComponent("wallet.enc"), key: key),
            outbox: try ReferralOutbox(storeURL: path.appendingPathComponent("outbox.enc"), key: key),
            chain: try MockChainClient(storeURL: path.appendingPathComponent("chain.json")), api: api, online: online,
            consultationOutbox: try ConsultationOutbox(storeURL: path.appendingPathComponent("consultations.enc"), key: key))
    }
    func testOwnershipLoginRequiresSignatureAndCodeAndIncludesExpiredProfiles() async throws {
        let own = try record(), expired = try record(now: Date().addingTimeInterval(-31 * 86400)), other = try record(code: "9876")
        let app = try session(folder(), api: MockReferralAPI(records: [own, expired, other]))
        let matches = try await app.patientProfiles(passcode: "0123", strokes: DemoData.signatureStrokes())
        XCTAssertEqual(Set(matches.map(\.id)), Set([own.id, expired.id]))
        let wrongCode = try await app.patientProfiles(passcode: "1111", strokes: DemoData.signatureStrokes())
        XCTAssertTrue(wrongCode.isEmpty)
        let different = [(0..<8).map { SignaturePoint(x: Double($0), y: Double(7 - $0)) }]
        let wrongSignature = try await app.patientProfiles(passcode: "0123", strokes: different)
        XCTAssertTrue(wrongSignature.isEmpty)
        #if DEBUG
        let bypass = try await app.patientProfiles(passcode: NativeSession.testingBypassPasscode, strokes: DemoData.signatureStrokes())
        XCTAssertTrue(bypass.isEmpty, "Clinician debug bypass cannot authorize patient erasure")
        #endif
    }
    func testDeletionPurgesWalletQueuesAndLocalRegistryWithoutRemovingAnotherPatient() async throws {
        let own = try record(), other = try record(code: "9876"), path = try folder()
        let api = MockReferralAPI(records: [own, other]), app = try session(path, api: api)
        for item in [own, other] {
            try await app.wallet.store(item, state: .pendingEnrollment)
            try await app.outbox.enqueue(item)
            try await app.chain.create(referralID: item.id, hash: item.commitmentHash)
        }
        try await app.outbox.enqueueSpend(PendingSpend(referralID: own.id, commitmentHash: own.commitmentHash))
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "consultation", withExtension: "json", subdirectory: "Fixtures"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        json["referral_id"] = own.id
        let consultation = try JSONDecoder().decode(ConsultationRecord.self, from: JSONSerialization.data(withJSONObject: json))
        try await app.consultationOutbox?.enqueue(consultation)
        let matches = try await app.patientProfiles(passcode: "0123", strokes: DemoData.signatureStrokes())
        let access = try XCTUnwrap(matches.first)
        try await app.deletePatientProfile(access)
        try await app.deletePatientProfile(access) // Lost-response retry.
        let entries = await app.walletEntries(), queue = await app.outbox.pending(), spends = await app.outbox.pendingSpends()
        XCTAssertEqual(entries.map(\.id), [other.id]); XCTAssertEqual(queue.map(\.id), [other.id]); XCTAssertTrue(spends.isEmpty)
        let consultations = await app.pendingConsultations(), account = try await app.chain.read(referralID: own.id)
        XCTAssertTrue(consultations.isEmpty); XCTAssertNil(account)
        let remote = try await api.list(); XCTAssertEqual(remote.map(\.id), [other.id])
        let reopened = try session(path, api: api)
        _ = try await reopened.sync()
        let persisted = await reopened.walletEntries(); XCTAssertEqual(persisted.map(\.id), [other.id])
        do { try await reopened.wallet.store(own); XCTFail("A late cached read must not restore the erased profile") }
        catch { XCTAssertEqual(error as? CoreError, .notFound) }
        do { try await reopened.outbox.enqueue(own); XCTFail("A stale enrollment must not be queued again") }
        catch { XCTAssertEqual(error as? CoreError, .notFound) }
    }
    func testOfflineAndStaleLoginCannotStartDeletion() async throws {
        let own = try record(), api = DeletionTestAPI(records: [])
        let app = try session(folder(), api: api, online: false)
        try await app.wallet.store(own)
        let access = try PatientProfileAccess(record: own, passcode: "0123", strokes: DemoData.signatureStrokes())
        do { try await app.deletePatientProfile(access); XCTFail("Remote deletion cannot complete offline") }
        catch { XCTAssertEqual(error as? CoreError, .offline) }
        let calls = await api.deleteCalls, requested = await app.wallet.deletionRequested(id: own.id)
        XCTAssertEqual(calls, 0); XCTAssertFalse(requested)
        let online = try session(folder(), api: api)
        let stale = try PatientProfileAccess(record: own, passcode: "0123", strokes: DemoData.signatureStrokes(), now: Date().addingTimeInterval(-301))
        do { try await online.deletePatientProfile(stale); XCTFail("A fresh login is required") }
        catch { XCTAssertEqual(error as? CoreError, .verificationFailed) }
    }
    func testFailureRetainsRecordForRetryAndRestartCannotReuploadDeletionIntent() async throws {
        let own = try record(), path = try folder(), api = DeletionTestAPI(records: [try record(code: "9876")])
        try await api.submit(own); await api.setFail(true)
        let app = try session(path, api: api)
        try await app.wallet.store(own, state: .pendingEnrollment); try await app.outbox.enqueue(own)
        let found = try await app.patientProfiles(passcode: "0123", strokes: DemoData.signatureStrokes())
        do { try await app.deletePatientProfile(try XCTUnwrap(found.first)); XCTFail("A transport error must not report success") }
        catch { XCTAssertTrue(error is URLError) }
        let entry = await app.wallet.entry(id: own.id); XCTAssertNotNil(entry)
        let reopened = try session(path, api: api)
        _ = try await reopened.sync()
        let queue = await reopened.outbox.pending(); XCTAssertTrue(queue.isEmpty)
        let stillThere = try await api.fetchVerificationEnvelope(id: own.id); XCTAssertEqual(stillThere.id, own.id)
        await api.setFail(false)
        let retry = try await reopened.patientProfiles(passcode: "0123", strokes: DemoData.signatureStrokes())
        try await reopened.deletePatientProfile(try XCTUnwrap(retry.first))
        let erased = await reopened.wallet.entry(id: own.id); XCTAssertNil(erased)
    }
    func testDeletedServerRecordCannotBlockUnrelatedOfflineUploads() async throws {
        let own = try record(), other = try record(code: "9876"), api = MockReferralAPI(records: [try record(code: "4321")])
        try await api.submit(own)
        try await api.deleteProfile(PatientProfileAccess(record: own, passcode: "0123", strokes: DemoData.signatureStrokes()))
        let app = try session(folder(), api: api)
        for item in [own, other] { try await app.wallet.store(item, state: .pendingEnrollment); try await app.outbox.enqueue(item) }
        _ = try await app.sync()
        let entries = await app.walletEntries(), queued = await app.outbox.pending()
        XCTAssertEqual(entries.map(\.id), [other.id]); XCTAssertTrue(queued.isEmpty)
        let uploaded = try await api.fetchVerificationEnvelope(id: other.id); XCTAssertEqual(uploaded.id, other.id)
    }
    func testMissingCommitmentAloneDoesNotEraseThePatientProfileOrQueuedSpend() async throws {
        let own = try record(), app = try session(folder(), api: MockReferralAPI(records: [try record(code: "9876")]))
        try await app.api.submit(own)
        try await app.wallet.store(own)
        try await app.outbox.enqueueSpend(PendingSpend(referralID: own.id, commitmentHash: own.commitmentHash))
        do { _ = try await app.sync(); XCTFail("A missing commitment requires reconciliation") }
        catch { XCTAssertEqual(error as? CoreError, .notFound) }
        let entry = await app.wallet.entry(id: own.id), spends = await app.outbox.pendingSpends()
        XCTAssertNotNil(entry); XCTAssertEqual(spends.map(\.referralID), [own.id])
        let deletion = await app.wallet.deletionRequested(id: own.id); XCTAssertFalse(deletion)
    }

    func testCrashAfterDeletionIntentDoesNotReplayAnEnrollmentOnRestart() async throws {
        let own = try record(), path = try folder(), api = MockReferralAPI()
        let app = try session(path, api: api)
        try await app.wallet.store(own, state: .pendingEnrollment)
        try await app.outbox.enqueue(own)
        try await app.wallet.beginDeletion(id: own.id) // Simulate termination before outbox cleanup.
        let reopened = try session(path, api: api)
        _ = try await reopened.sync()
        let uploaded = try await api.list(), queued = await reopened.outbox.pending()
        XCTAssertTrue(uploaded.isEmpty); XCTAssertTrue(queued.isEmpty)
    }

    func testExistingEncryptedArrayWalletMigratesWithoutLosingRecords() async throws {
        let own = try record(), path = try folder().appendingPathComponent("legacy.enc")
        try LocalStorage(url: path, key: key).write([WalletEntry(record: own)])
        let wallet = try ReferralWallet(storeURL: path, key: key)
        try await wallet.beginDeletion(id: own.id)
        let reopened = try ReferralWallet(storeURL: path, key: key)
        let records = await reopened.records(), blocked = await reopened.deletionRequested(id: own.id)
        XCTAssertEqual(records, [own]); XCTAssertTrue(blocked)
    }
}
private actor DeletionTestAPI: ReferralAPI {
    private let backing: MockReferralAPI
    private var fail = false
    private(set) var deleteCalls = 0
    init(records: [ReferralRecord]) { backing = MockReferralAPI(records: records) }
    func setFail(_ value: Bool) { fail = value }
    func submit(_ record: ReferralRecord) async throws { try await backing.submit(record) }
    func list() async throws -> [ReferralRecord] { try await backing.list() }
    func fetchVerificationEnvelope(id: String) async throws -> ReferralRecord { try await backing.fetchVerificationEnvelope(id: id) }
    func deleteProfile(_ access: PatientProfileAccess) async throws {
        deleteCalls += 1
        if fail { throw URLError(.networkConnectionLost) }
        try await backing.deleteProfile(access)
    }
}
