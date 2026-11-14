import Combine
import Foundation
import XCTest
@testable import EdgeCareUI

final class AudioNotificationObserverTests: XCTestCase {
    @MainActor func testBackgroundEngineNotificationHopsToMainActor() async {
        let name = Notification.Name("synthetic.audio.configuration.\(UUID().uuidString)")
        let received = expectation(description: "Engine notification delivered on UI actor")
        let token = AudioNotificationObserver.observe(name, codeKey: "reason") { event in
            MainActor.assertIsolated()
            XCTAssertEqual(event.code, 2)
            received.fulfill()
        }
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: name, object: nil, userInfo: ["reason": UInt(2)])
        }
        await fulfillment(of: [received], timeout: 2)
        withExtendedLifetime(token) {}
    }

    @MainActor func testConfigurationNotificationWithoutMetadataIsSupported() async {
        let name = Notification.Name("synthetic.audio.configuration.\(UUID().uuidString)")
        let received = expectation(description: "Configuration notification with no payload")
        let token = AudioNotificationObserver.observe(name) { event in
            MainActor.assertIsolated()
            XCTAssertNil(event.code)
            received.fulfill()
        }
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: name, object: nil)
        }
        await fulfillment(of: [received], timeout: 2)
        withExtendedLifetime(token) {}
    }
}
