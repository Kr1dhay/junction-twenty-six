import Foundation
import Combine

/// Audio notifications are posted on engine/session queues. Extract only Sendable
/// metadata there, then explicitly hop to the UI actor. An actor-inherited Combine
/// sink can otherwise trap before even reaching a Task { @MainActor ... }.
enum AudioNotificationObserver {
    struct Event: Sendable {
        let code: UInt?
        let occurred: ContinuousClock.Instant
    }

    @MainActor static func observe(_ name: Notification.Name, object: AnyObject? = nil,
                                   codeKey: String? = nil,
                                   receive: @escaping @MainActor @Sendable (Event) -> Void) -> AnyCancellable {
        NotificationCenter.default.publisher(for: name, object: object).sink { @Sendable notification in
            let code = codeKey.flatMap { notification.userInfo?[$0] as? UInt }
            let event = Event(code: code, occurred: .now)
            Task { @MainActor in receive(event) }
        }
    }
}
