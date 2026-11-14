import CryptoKit
import XCTest
@testable import EdgeCareCore

final class WalletKeyMigrationTests: XCTestCase {
    func testKeyAccountSurvivesSandboxRelocationButIsIsolatedByAppAndRelativeDirectory() {
        func account(home: String, directory: String = "Library/Application Support/EdgeCare", bundle: String = "org.edgecare.demo.doctor") -> String {
            NativeSession.storageAccount(directory: URL(fileURLWithPath: home).appendingPathComponent(directory),
                home: URL(fileURLWithPath: home), bundleIdentifier: bundle)
        }
        XCTAssertEqual(account(home: "/sandbox/old"), account(home: "/sandbox/new"))
        XCTAssertNotEqual(account(home: "/sandbox/old"), account(home: "/sandbox/new", bundle: "org.edgecare.demo.kiosk"))
        XCTAssertNotEqual(account(home: "/sandbox/old"), account(home: "/sandbox/old", directory: "Library/Application Support/Other"))
    }

    func testOnlyKeyAuthenticatingEveryExistingFileCanBeRecovered() throws {
        let key = Data(repeating: 7, count: 32), wrong = Data(repeating: 9, count: 32)
        func encrypt(_ data: Data, key: Data) throws -> Data {
            try XCTUnwrap(AES.GCM.seal(data, using: SymmetricKey(data: key)).combined)
        }
        let wallet = try encrypt(Data("synthetic wallet".utf8), key: key)
        let outbox = try encrypt(Data("synthetic outbox".utf8), key: key)
        XCTAssertEqual(KeychainStore.matchingWalletKey(encryptedFiles: [wallet, outbox], candidates: [wrong, Data(), key]), key)
        XCTAssertNil(KeychainStore.matchingWalletKey(encryptedFiles: [wallet, try encrypt(Data(), key: wrong)], candidates: [key, wrong]))
        XCTAssertNil(KeychainStore.matchingWalletKey(encryptedFiles: [Data([1, 2, 3])], candidates: [key]))
        XCTAssertNil(KeychainStore.matchingWalletKey(encryptedFiles: [], candidates: [key]))
        XCTAssertNil(KeychainStore.matchingWalletKey(encryptedFiles: [wallet], candidates: [wrong]))
    }
}
