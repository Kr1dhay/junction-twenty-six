import XCTest
@testable import EdgeCareUI

final class BundledConnectionTests: XCTestCase {
    private let info: [String: Any] = [
        "EDGECARE_MODE": "connected",
        "EDGECARE_BASE_URL": "https://example.invalid",
        "EDGECARE_ISSUER_TOKEN": "synthetic-issuer",
        "EDGECARE_CLINICIAN_TOKEN": "",
        "CFBundleName": "Kiosk"
    ]
    func testHomeScreenLaunchUsesBundledConnection() {
        let environment = BundledConnection.resolve(environment: ["OTHER": "kept"], info: info)
        XCTAssertEqual(environment["EDGECARE_MODE"], "connected")
        XCTAssertEqual(environment["EDGECARE_BASE_URL"], "https://example.invalid")
        XCTAssertEqual(environment["EDGECARE_ISSUER_TOKEN"], "synthetic-issuer")
        XCTAssertNil(environment["EDGECARE_CLINICIAN_TOKEN"])
        XCTAssertEqual(environment["OTHER"], "kept")
    }
    func testExplicitLaunchEnvironmentWins() {
        let explicit = ["EDGECARE_MODE": "local"]
        XCTAssertEqual(BundledConnection.resolve(environment: explicit, info: info), explicit)
    }
    func testSimulatorBuildWithoutBundledSettingsStaysLocal() {
        let empty: [String: Any] = ["EDGECARE_MODE": "", "EDGECARE_BASE_URL": ""]
        XCTAssertEqual(BundledConnection.resolve(environment: [:], info: empty), [:])
        XCTAssertEqual(BundledConnection.resolve(environment: [:], info: nil), [:])
    }
    func testNonHTTPSBundledOriginIsIgnored() {
        var insecure = info
        insecure["EDGECARE_BASE_URL"] = "http://example.invalid"
        XCTAssertEqual(BundledConnection.resolve(environment: [:], info: insecure), [:])
    }
}
