import XCTest
@testable import EdgeCareCore

final class StorageKeyTests: XCTestCase {
    /// iOS gives a reinstalled or updated app a new container path but keeps its files;
    /// the wallet key name must not change with it.
    func testKeyNameSurvivesContainerMove() {
        let before = "/data/Containers/Data/Application/15418A1A-FDA8-4369-B87A-45627DDD1278"
        let after = "/data/Containers/Data/Application/D3462CAA-1B6A-4C90-9945-350BF78F3840"
        let suffix = "Library/Application Support/EdgeCare"
        XCTAssertEqual(
            NativeSession.storageAccount(directory: URL(fileURLWithPath: before + "/" + suffix), home: before),
            NativeSession.storageAccount(directory: URL(fileURLWithPath: after + "/" + suffix), home: after))
    }

    func testDifferentDirectoriesGetDifferentKeys() {
        let home = "/data/Containers/Data/Application/D3462CAA-1B6A-4C90-9945-350BF78F3840"
        XCTAssertNotEqual(
            NativeSession.storageAccount(directory: URL(fileURLWithPath: home + "/Library/Application Support/EdgeCare"), home: home),
            NativeSession.storageAccount(directory: URL(fileURLWithPath: home + "/Library/Application Support/Other"), home: home))
        // Directories outside the home (tests, temporary stores) keep a distinct absolute name.
        XCTAssertNotEqual(
            NativeSession.storageAccount(directory: URL(fileURLWithPath: "/tmp/a"), home: home),
            NativeSession.storageAccount(directory: URL(fileURLWithPath: "/tmp/b"), home: home))
    }
}
