import XCTest
@testable import EdgeCareUI

final class DoctorConnectionSettingsTests: XCTestCase {
    private let provisioned = [
        "EDGECARE_MODE": "connected",
        "EDGECARE_BASE_URL": "https://example.invalid",
        "EDGECARE_CLINICIAN_TOKEN": "synthetic-clinician-token",
        "EDGECARE_ISSUER_TOKEN": "synthetic-issuer-must-not-persist"
    ]
    private func saved() throws -> Data {
        try JSONEncoder().encode(XCTUnwrap(DoctorConnectionSettings(environment: provisioned)))
    }
    func testHomeScreenLaunchRestoresConnectionWithoutPersistingIssuer() throws {
        let environment = DoctorConnectionSettings.resolve(environment: ["OTHER": "kept"], saved: try saved())
        XCTAssertEqual(environment["EDGECARE_MODE"], "connected")
        XCTAssertEqual(environment["EDGECARE_BASE_URL"], provisioned["EDGECARE_BASE_URL"])
        XCTAssertEqual(environment["EDGECARE_CLINICIAN_TOKEN"], provisioned["EDGECARE_CLINICIAN_TOKEN"])
        XCTAssertEqual(environment["OTHER"], "kept")
        XCTAssertNil(environment["EDGECARE_ISSUER_TOKEN"])
        XCTAssertFalse(String(decoding: try saved(), as: UTF8.self).contains("synthetic-issuer"))
    }
    func testExplicitLocalModeOverridesSavedConnection() throws {
        let explicit = ["EDGECARE_MODE": "local"]
        XCTAssertEqual(DoctorConnectionSettings.resolve(environment: explicit, saved: try saved()), explicit)
    }
    func testNewHostNeverInheritsSavedCredential() throws {
        let explicit = ["EDGECARE_MODE": "connected", "EDGECARE_BASE_URL": "https://other.invalid"]
        XCTAssertEqual(DoctorConnectionSettings.resolve(environment: explicit, saved: try saved()), explicit)
    }
    func testFreshInstallAndCorruptSettingsStayUnprovisioned() {
        XCTAssertEqual(DoctorConnectionSettings.resolve(environment: [:], saved: nil), [:])
        XCTAssertEqual(DoctorConnectionSettings.resolve(environment: [:], saved: Data("invalid".utf8)), [:])
    }
    func testOnlyAuthenticatedHTTPSOriginsCanBePersisted() {
        for origin in ["http://example.invalid", "http://127.0.0.1:3000", "https://user:password@example.invalid",
                       "https://example.invalid?token=unsafe", "https://example.invalid/#fragment",
                       "https://example.invalid/another-api"] {
            var environment = provisioned; environment["EDGECARE_BASE_URL"] = origin
            XCTAssertNil(DoctorConnectionSettings(environment: environment), origin)
        }
        var environment = provisioned; environment["EDGECARE_CLINICIAN_TOKEN"] = ""
        XCTAssertNil(DoctorConnectionSettings(environment: environment))
    }
    func testSavedContentsAreValidatedBeforeReuse() throws {
        let invalid = Data(#"{"baseURL":"http://example.invalid","clinicianToken":"synthetic"}"#.utf8)
        XCTAssertEqual(DoctorConnectionSettings.resolve(environment: [:], saved: invalid), [:])
    }
    func testLegacyClinicianTokenCanProvisionButLocalModeCannot() {
        var environment = provisioned
        environment.removeValue(forKey: "EDGECARE_CLINICIAN_TOKEN")
        environment["EDGECARE_API_TOKEN"] = "synthetic-legacy-token"
        XCTAssertEqual(DoctorConnectionSettings(environment: environment)?.clinicianToken, "synthetic-legacy-token")
        environment["EDGECARE_MODE"] = "local"
        XCTAssertNil(DoctorConnectionSettings(environment: environment))
    }
}
