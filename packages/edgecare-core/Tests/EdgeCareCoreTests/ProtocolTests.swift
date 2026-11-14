import XCTest
@testable import EdgeCareCore

@MainActor final class ProtocolTests: XCTestCase {
    func testCryptoRoundTripAndWrongPasscode() throws {
        let salt = try CommitmentCrypto.randomSalt()
        let plaintext = Data("private template".utf8)
        let encrypted = try CommitmentCrypto.encrypt(plaintext, passcode: "0123", salt: salt)
        XCTAssertEqual(try CommitmentCrypto.decrypt(encrypted, passcode: "0123", salt: salt), plaintext)
        XCTAssertThrowsError(try CommitmentCrypto.decrypt(encrypted, passcode: "9999", salt: salt))
        for invalid in ["123", "12345", "abcd", "١٢٣٤"] { XCTAssertThrowsError(try CommitmentCrypto.validate(passcode: invalid)) }
    }
    func testCrossLanguageFixtureAndCommitment() throws {
        let records = try DemoData.referrals()
        XCTAssertEqual(records.count, 3)
        let record = records[0]
        let salt = try XCTUnwrap(Data(base64Encoded: record.salt))
        let template = try CommitmentCrypto.decrypt(XCTUnwrap(Data(base64Encoded: record.signatureTemplateEncrypted)), passcode: "1234", salt: salt)
        XCTAssertEqual(try CommitmentCrypto.commitment(template: template, passcode: "1234", referralID: XCTUnwrap(UUID(uuidString: record.id)), salt: salt), record.commitmentHash)
        XCTAssertEqual(try JSONDecoder().decode(SignatureTemplate.self, from: template).points.count, 32)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        XCTAssertTrue(wire["kiosk_id"] is NSNull)
    }
    func testSignatureThresholdAndNormalization() throws {
        let diagonal = (0..<8).map { SignaturePoint(x: Double($0), y: Double($0)) }
        let translated = diagonal.map { SignaturePoint(x: $0.x * 2 + 10, y: $0.y * 2 + 20) }
        let other = (0..<8).map { SignaturePoint(x: Double($0), y: Double(7 - $0)) }
        let enrolled = try SignatureMatcher.extract([diagonal])
        XCTAssertGreaterThanOrEqual(SignatureMatcher.similarity(enrolled, try SignatureMatcher.extract([translated])), SignatureMatcher.threshold)
        XCTAssertLessThan(SignatureMatcher.similarity(enrolled, try SignatureMatcher.extract([other])), SignatureMatcher.threshold)
        XCTAssertThrowsError(try SignatureMatcher.extract([]))
    }
    func testVerifySpendPersistAndRejectReplay() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("chain.json")
        let record = try DemoData.referrals()[0]
        let chain = try MockChainClient(storeURL: url)
        try await chain.create(referralID: record.id, hash: record.commitmentHash)
        try await chain.create(referralID: record.id, hash: record.commitmentHash)
        let service = VerificationService(chain: chain)
        let strokes = [(0..<8).map { SignaturePoint(x: Double($0), y: Double($0)) }]
        let now = Date(timeIntervalSince1970: 1794657600)
        do {
            try await service.verifyAndSpend(record: record, passcode: "9999", strokes: strokes, now: now)
            XCTFail("Wrong passcode must fail")
        } catch {}
        let before = await chain.read(referralID: record.id)
        XCTAssertEqual(before?.spent, false)
        try await service.verifyAndSpend(record: record, passcode: "1234", strokes: strokes, now: now)
        let reopened = try MockChainClient(storeURL: url)
        let after = await reopened.read(referralID: record.id)
        XCTAssertEqual(after?.spent, true)
        do { try await reopened.spend(referralID: record.id); XCTFail("Replay must fail") }
        catch { XCTAssertEqual(error as? CoreError, .alreadySpent) }
    }
    func testAuthenticationStillWorksAfterSingleUse() throws {
        // Identity verification is independent of consumption: a spent referral must still
        // authenticate its patient so the clinician can log a new visit.
        let record = try DemoData.referrals()[0]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object["status"] = "spent"
        let spent = try JSONDecoder().decode(ReferralRecord.self, from: JSONSerialization.data(withJSONObject: object))
        let hash = try VerificationService.authenticate(record: spent, passcode: "1234", strokes: [(0..<8).map { SignaturePoint(x: Double($0), y: Double($0)) }])
        XCTAssertEqual(hash, record.commitmentHash)
    }
    func testOutboxPersistsAndDoesNotSyncInDemoMode() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("outbox.json")
        let outbox = try ReferralOutbox(storeURL: url)
        let record = try DemoData.referrals()[0]
        try await outbox.enqueue(record)
        let api = MockReferralAPI()
        let chain = try MockChainClient(storeURL: folder.appendingPathComponent("chain.json"))
        try await outbox.sync(chain: chain, api: api, configuration: .demo)
        let reopened = try ReferralOutbox(storeURL: url)
        let pending = await reopened.pending()
        XCTAssertEqual(pending.count, 1)
        let account = await chain.read(referralID: record.id)
        XCTAssertNil(account)
        try await reopened.sync(chain: chain, api: api, configuration: AppConfiguration(demoMode: false, offline: false))
        let synced = await reopened.pending()
        XCTAssertTrue(synced.isEmpty)
    }
    func testUnsafeDemoConfigurationRejected() {
        XCTAssertThrowsError(try AppConfiguration(chain: .devnet))
        XCTAssertThrowsError(try AppConfiguration(llm: .gemini))
    }
}
