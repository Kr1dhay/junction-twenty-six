import XCTest
@testable import EdgeCareCore

@MainActor final class ReferralUpdateTests: XCTestCase {
    private func draft(duration: String) -> EnrollmentDraft {
        let profile = ClinicalProfile(concernEnglish: "Cough", symptomsEnglish: ["Cough"], durationEnglish: duration)
        return EnrollmentDraft(source: .kiosk, language: "fi", concern: "Synthetic patient notes", guidance: TriageGuidance(message: "Synthetic guidance"), letterText: "Synthetic letter", answers: ["urgent_now": "no"], clinicalProfile: profile)
    }
    private func record() throws -> ReferralRecord {
        try EnrollmentService().enroll(draft: draft(duration: "Two days"), strokes: DemoData.signatureStrokes(), passcode: "0123", confirmation: "0123")
    }
    private func unlock(_ record: ReferralRecord) throws -> ReferralEditSession {
        try EnrollmentService().unlock(record: record, passcode: "0123", strokes: DemoData.signatureStrokes())
    }
    func testOnlyMatchingCodeAndSignatureUnlockTheStoredProfile() throws {
        let original = try record()
        XCTAssertThrowsError(try EnrollmentService().unlock(record: original, passcode: "9999", strokes: DemoData.signatureStrokes()))
        let other = [(0..<8).map { SignaturePoint(x: Double($0), y: Double(7 - $0)) }]
        XCTAssertThrowsError(try EnrollmentService().unlock(record: original, passcode: "0123", strokes: other))
        let edit = try unlock(original)
        XCTAssertEqual(edit.clinicalProfile.durationEnglish, "Two days")
        XCTAssertEqual(edit.letterText, "Synthetic letter")
        XCTAssertEqual(edit.answers["urgent_now"], "no")
    }
    func testUpdatePreservesIdentityAndCredentialsWhileReplacingEncryptedClinicalData() throws {
        let original = try record(), edit = try unlock(original)
        let update = try EnrollmentService().prepareUpdate(session: edit, draft: draft(duration: "Five days"))
        XCTAssertTrue(update.preservesIdentity)
        XCTAssertEqual(update.record.id, original.id)
        XCTAssertEqual(update.record.signatureTemplateEncrypted, original.signatureTemplateEncrypted)
        XCTAssertEqual(update.record.commitmentHash, original.commitmentHash)
        XCTAssertEqual(update.record.expiresAt, original.expiresAt)
        XCTAssertNotEqual(update.record.triageDetailEncrypted, original.triageDetailEncrypted)
        XCTAssertEqual(try unlock(update.record).clinicalProfile.durationEnglish, "Five days")
        _ = try VerificationService.authenticate(record: update.record, passcode: "0123", strokes: DemoData.signatureStrokes())
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any]
        XCTAssertNil(wire?["passcode"])
        XCTAssertNil(wire?["key"])
    }
    func testMockUpdateRetriesAreIdempotentAndStaleEditorsCannotOverwrite() async throws {
        let original = try record(), edit = try unlock(original)
        let api = MockReferralAPI(records: [original])
        let first = try EnrollmentService().prepareUpdate(session: edit, draft: draft(duration: "Five days"))
        try await api.update(first); try await api.update(first)
        let records = try await api.list()
        XCTAssertEqual(records, [first.record])
        let stale = try EnrollmentService().prepareUpdate(session: edit, draft: draft(duration: "Six days"))
        do { try await api.update(stale); XCTFail("Stale update must fail") }
        catch { XCTAssertEqual(error as? CoreError, .conflict) }
    }
    func testUpdatingUsedReferralKeepsSpentRegistryAndDoesNotCreateAnotherRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 45, count: 32), original = try record()
        let chain = try MockChainClient(storeURL: directory.appendingPathComponent("chain.json"))
        let api = MockReferralAPI(records: [original])
        let session = NativeSession(configuration: .connectedDemo,
            wallet: try ReferralWallet(storeURL: directory.appendingPathComponent("wallet.enc"), key: key),
            outbox: try ReferralOutbox(storeURL: directory.appendingPathComponent("outbox.enc"), key: key), chain: chain, api: api)
        try await chain.create(referralID: original.id, hash: original.commitmentHash)
        try await chain.spend(referralID: original.id, hash: original.commitmentHash, operationID: UUID().uuidString.lowercased())
        let before = await chain.read(referralID: original.id)
        let edit = try unlock(original), update = try EnrollmentService().prepareUpdate(session: edit, draft: draft(duration: "Five days"))
        let saved = try await session.updateReferral(update, authorization: edit)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(try unlock(saved).clinicalProfile.durationEnglish, "Five days")
        let after = await chain.read(referralID: original.id), records = try await api.list()
        XCTAssertEqual(before, after)
        XCTAssertEqual(records.count, 1)
        let state = await session.wallet.entry(id: original.id)?.state
        XCTAssertEqual(state, .spent)
        await session.setOnline(false)
        do { _ = try await session.updateReferral(update, authorization: edit); XCTFail("Connected updates need a connection") }
        catch { XCTAssertEqual(error as? CoreError, .offline) }
    }
}
