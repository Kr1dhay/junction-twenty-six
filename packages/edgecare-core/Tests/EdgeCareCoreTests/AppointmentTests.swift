import XCTest
@testable import EdgeCareCore

@MainActor final class AppointmentTests: XCTestCase {
    private func session(configuration: AppConfiguration = .connectedDemo, online: Bool = true, api: any AppointmentAPI) throws -> NativeSession {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 17, count: 32)
        return NativeSession(configuration: configuration,
            wallet: try ReferralWallet(storeURL: directory.appendingPathComponent("wallet.enc"), key: key),
            outbox: try ReferralOutbox(storeURL: directory.appendingPathComponent("outbox.enc"), key: key),
            chain: try MockChainClient(storeURL: directory.appendingPathComponent("registry.json")),
            api: MockReferralAPI(), online: online, appointmentAPI: api)
    }
    private func record() throws -> ReferralRecord {
        try EnrollmentService().enroll(draft: EnrollmentDraft(source: .kiosk, language: "en", concern: "Synthetic booking test",
            guidance: TriageGuidance(message: "Clinician review")), strokes: DemoData.signatureStrokes(), passcode: "0123", confirmation: "0123")
    }
    func testOfflineAndLocalModesCannotReserveSharedSlotsOrQueueBookings() async throws {
        let record = try record(), service = AppointmentSpy()
        let proof = PatientVerification(referralID: record.id, commitmentHash: record.commitmentHash)
        for configuration in [AppConfiguration.demo, .connectedDemo] {
            let app = try session(configuration: configuration, online: false, api: service)
            do {
                _ = try await app.bookAppointment(record: record, verification: proof, slotID: "slot", operationID: UUID().uuidString.lowercased())
                XCTFail("An offline device cannot confirm a shared appointment")
            } catch { XCTAssertEqual(error as? CoreError, .offline) }
            let pending = await app.outbox.pending()
            XCTAssertTrue(pending.isEmpty)
        }
        let calls = await service.calls
        XCTAssertEqual(calls, 0)
    }
    func testWrongOrStalePatientProofFailsBeforeAnyBookingRequest() async throws {
        let record = try record(), service = AppointmentSpy()
        let app = try session(api: service)
        for proof in [
            PatientVerification(referralID: UUID().uuidString, commitmentHash: record.commitmentHash),
            PatientVerification(referralID: record.id, commitmentHash: String(repeating: "f", count: 64)),
            PatientVerification(referralID: record.id, commitmentHash: record.commitmentHash, verifiedAt: Date().addingTimeInterval(-901)),
        ] {
            do { _ = try await app.appointmentAvailability(record: record, verification: proof); XCTFail("Invalid patient proof") }
            catch { XCTAssertEqual(error as? CoreError, .verificationFailed) }
        }
        let calls = await service.calls
        XCTAssertEqual(calls, 0)
    }
    func testBookingUsesLocallyVerifiedAccessWithoutSpendingOrRetainingCredentials() async throws {
        let record = try record(), service = AppointmentSpy()
        let app = try session(api: service)
        try await app.chain.create(referralID: record.id, hash: record.commitmentHash)
        let proof = try await app.verify(record: record, passcode: "0123", strokes: DemoData.signatureStrokes())
        let operation = UUID().uuidString.lowercased()
        let booked = try await app.bookAppointment(record: record, verification: proof, slotID: "synthetic-slot", operationID: operation)
        XCTAssertEqual(booked.appointmentID, operation)
        let account = try await app.chain.read(referralID: record.id)
        XCTAssertEqual(account?.spent, false)
        let pending = await app.outbox.pending()
        XCTAssertTrue(pending.isEmpty)
        try await app.cancelAppointment(record: record, verification: proof, appointmentID: operation)
        let calls = await service.calls
        XCTAssertEqual(calls, 2)
        let edit = try EnrollmentService().unlock(record: record, passcode: "0123", strokes: DemoData.signatureStrokes())
        let editProof = await app.appointmentVerification(for: edit)
        XCTAssertEqual(editProof.referralID, record.id)
        XCTAssertEqual(editProof.commitmentHash, record.commitmentHash)
    }
}

private actor AppointmentSpy: AppointmentAPI {
    private(set) var calls = 0
    func slots() -> [AppointmentSlot] { calls += 1; return [] }
    func appointment(referralID: String) -> AppointmentBooking? { calls += 1; return nil }
    func book(referralID: String, slotID: String, operationID: String) -> AppointmentBooking {
        calls += 1
        return AppointmentBooking(appointmentID: operationID, referralID: referralID, slotID: slotID,
            startsAt: "2030-01-01T07:00:00.000Z", endsAt: "2030-01-01T07:30:00.000Z",
            timeZone: "Europe/Helsinki", location: "Edge-Care demo clinic", service: "Clinician review", status: "booked", demo: true)
    }
    func cancel(referralID: String, appointmentID: String) { calls += 1 }
}
