import Foundation

/// A notification the host posts: the center that posts it and its name.
///
/// The AppKit layer names each one (``HostNotifications``); the core observes
/// it without naming the platform's notification, and a test posts into a
/// center of its own.
struct HostNotification: Sendable {
    let center: NotificationCenter
    let name: Notification.Name

    /// Calls `handler` on the main actor each time the notification posts,
    /// until the returned observation is released.
    func observe(_ handler: @escaping @MainActor () -> Void) -> Observation {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            // `queue: .main` delivers on the main thread.
            MainActor.assumeIsolated { handler() }
        }
        return Observation(center: center, token: token)
    }

    /// One registration with a center, removed from it when released.
    final class Observation {
        private let center: NotificationCenter
        private let token: any NSObjectProtocol

        fileprivate init(center: NotificationCenter, token: any NSObjectProtocol) {
            self.center = center
            self.token = token
        }

        deinit {
            center.removeObserver(token)
        }
    }
}

/// The host notifications the core observes, built once by the composition
/// root.
struct HostNotifications: Sendable {
    /// The app became the active app — when the user looks again.
    let appDidBecomeActive: HostNotification
    /// The system is about to sleep; nothing holds it.
    let systemWillSleep: HostNotification
    /// The system woke from sleep.
    let systemDidWake: HostNotification
    /// A volume was mounted.
    let volumeDidMount: HostNotification
    /// A volume was unmounted.
    let volumeDidUnmount: HostNotification
}
