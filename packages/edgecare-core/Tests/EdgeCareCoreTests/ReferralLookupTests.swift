import XCTest
@testable import EdgeCareCore

@MainActor final class ReferralLookupTests: XCTestCase {
    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func record(passcode: String = "0123", strokes: [[SignaturePoint]] = DemoData.signatureStrokes(), now: Date = Date()) throws -> ReferralRecord {
        try EnrollmentService().enroll(draft: EnrollmentDraft(source: .kiosk, language: "en", concern: "Synthetic cough",
            guidance: TriageGuidance(message: "Clinician review requested.")), strokes: strokes, passcode: passcode,
            confirmation: passcode, now: now)
    }
    private func session(directory: URL, api: any ReferralAPI, online: Bool = true) throws -> NativeSession {
        let key = Data(repeating: 29, count: 32)
        return NativeSession(configuration: .connectedDemo,
            wallet: try ReferralWallet(storeURL: directory.appendingPathComponent("wallet.enc"), key: key),
            outbox: try ReferralOutbox(storeURL: directory.appendingPathComponent("outbox.enc"), key: key),
            chain: try MockChainClient(storeURL: directory.appendingPathComponent("registry.json")), api: api, online: online)
    }

    func testFullIDLookupNormalizesAndRetrievesWithoutPatientSecrets() async throws {
        let record = try record(), directory = try folder()
        let app = try session(directory: directory, api: MockReferralAPI(records: [record]))
        let found = try await app.cacheReferral(id: record.id.uppercased())
        XCTAssertEqual(found, record)
        let cached = await app.wallet.records()
        XCTAssertEqual(cached, [record])
    }

    func testSignatureAndCodeReturnAllMatchesWithoutSpendingOrPickingAnIdentity() async throws {
        let first = try record(), second = try record(), wrongPIN = try record(passcode: "9876")
        let otherSignature = [(0..<8).map { SignaturePoint(x: Double($0), y: Double(7 - $0)) }]
        let wrongSignature = try record(strokes: otherSignature)
        let expired = try record(now: Date().addingTimeInterval(-31 * 24 * 60 * 60))
        let app = try session(directory: folder(), api: MockReferralAPI(records: [first, second, wrongPIN, wrongSignature, expired]))
        try await app.chain.create(referralID: first.id, hash: first.commitmentHash)
        try await app.chain.create(referralID: second.id, hash: second.commitmentHash)
        let result = try await app.findReferrals(passcode: "0123", strokes: DemoData.signatureStrokes())
        XCTAssertFalse(result.searchedLocalOnly)
        XCTAssertEqual(Set(result.matches.map(\.id)), Set([first.id, second.id]))
        let cached = await app.wallet.records()
        XCTAssertEqual(Set(cached.map(\.id)), Set([first.id, second.id]))
        for match in result.matches {
            XCTAssertEqual(match.verification.referralID, match.id)
            XCTAssertEqual(match.verification.commitmentHash, match.record.commitmentHash)
            let account = try await app.chain.read(referralID: match.id)
            XCTAssertEqual(account?.spent, false)
        }
        let chosen = try XCTUnwrap(result.matches.first)
        _ = try await app.markUsed(record: chosen.record, verification: chosen.verification)
        let account = try await app.chain.read(referralID: chosen.id)
        XCTAssertEqual(account?.spent, true, "Only a separate explicit action consumes the chosen referral")
    }

    func testUsedReferralRemainsSearchableWithoutReopeningItsState() async throws {
        let record = try record()
        let app = try session(directory: folder(), api: MockReferralAPI(records: [record]))
        try await app.chain.create(referralID: record.id, hash: record.commitmentHash)
        _ = try await app.cacheReferral(id: record.id)
        let verification = try await app.verify(record: record, passcode: "0123", strokes: DemoData.signatureStrokes())
        _ = try await app.markUsed(record: record, verification: verification)
        let result = try await app.findReferrals(passcode: "0123", strokes: DemoData.signatureStrokes())
        XCTAssertEqual(result.matches.map(\.id), [record.id])
        let state = await app.wallet.entry(id: record.id)?.state
        XCTAssertEqual(state, .spent)
    }

    func testOfflineSearchUsesOnlyTheEncryptedCacheAndMakesNoAPIRequest() async throws {
        let record = try record(), api = LookupSpyAPI()
        let app = try session(directory: folder(), api: api, online: false)
        try await app.wallet.store(record)
        let result = try await app.findReferrals(passcode: "0123", strokes: DemoData.signatureStrokes())
        XCTAssertTrue(result.searchedLocalOnly)
        XCTAssertEqual(result.matches.map(\.id), [record.id])
        let calls = await api.listCalls
        XCTAssertEqual(calls, 0)
        let empty = try await app.findReferrals(passcode: "9876", strokes: DemoData.signatureStrokes())
        XCTAssertTrue(empty.matches.isEmpty)
    }

    func testTransportFallbackReportsCacheScopeAndAuthErrorsNeverFallBack() async throws {
        let record = try record()
        let app = try session(directory: folder(), api: LookupSpyAPI(failure: .transport))
        try await app.wallet.store(record)
        let fallback = try await app.findReferrals(passcode: "0123", strokes: DemoData.signatureStrokes())
        XCTAssertTrue(fallback.searchedLocalOnly)
        XCTAssertEqual(fallback.matches.map(\.id), [record.id])
        let forbidden = try session(directory: folder(), api: LookupSpyAPI(failure: .unauthorized))
        try await forbidden.wallet.store(record)
        do {
            _ = try await forbidden.findReferrals(passcode: "0123", strokes: DemoData.signatureStrokes())
            XCTFail("Authorization errors cannot silently search cached records")
        } catch { XCTAssertEqual(error as? CoreError, .unauthorized) }
    }

    func testInvalidCredentialsFailBeforeAnyNetworkRequest() async throws {
        let api = LookupSpyAPI(), app = try session(directory: folder(), api: api)
        do { _ = try await app.findReferrals(passcode: "123", strokes: DemoData.signatureStrokes()); XCTFail("Invalid code") }
        catch { XCTAssertEqual(error as? CoreError, .invalidPasscode) }
        do { _ = try await app.findReferrals(passcode: "0123", strokes: []); XCTFail("Invalid signature") }
        catch { XCTAssertEqual(error as? CoreError, .invalidSignature) }
        let calls = await api.listCalls
        XCTAssertEqual(calls, 0)
    }
}

private actor LookupSpyAPI: ReferralAPI {
    enum Failure: Sendable { case none, transport, unauthorized }
    let failure: Failure
    private(set) var listCalls = 0
    init(failure: Failure = .none) { self.failure = failure }
    func list() throws -> [ReferralRecord] {
        listCalls += 1
        switch failure {
        case .none: return []
        case .transport: throw URLError(.notConnectedToInternet)
        case .unauthorized: throw CoreError.unauthorized
        }
    }
    func submit(_ record: ReferralRecord) throws { throw CoreError.notConfigured }
    func fetchVerificationEnvelope(id: String) throws -> ReferralRecord { throw CoreError.notConfigured }
}
