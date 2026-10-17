import Foundation

/// A notification the host posts: the center that posts it and its name.
///
/// The AppKit layer names each one (``HostNotifications``); the core observes
/// it without naming the platform's notification, and a test posts into a
/// center of its own.
package struct HostNotification: Sendable {
    let center: NotificationCenter
    let name: Notification.Name

    package init(center: NotificationCenter, name: Notification.Name) {
        self.center = center
        self.name = name
    }

    /// Calls `handler` on the main actor each time the notification posts,
    /// until the returned observation is released.
    package func observe(_ handler: @escaping @MainActor () -> Void) -> Observation {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            // `queue: .main` delivers on the main thread.
            MainActor.assumeIsolated { handler() }
        }
        return Observation(center: center, token: token)
    }

    /// One registration with a center, removed from it when released.
    package final class Observation {
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
package struct HostNotifications: Sendable {
    /// The app became the active app — when the user looks again.
    package let appDidBecomeActive: HostNotification
    /// The system is about to sleep; nothing holds it.
    package let systemWillSleep: HostNotification
    /// The system woke from sleep.
    package let systemDidWake: HostNotification
    /// A volume was mounted.
    let volumeDidMount: HostNotification
    /// A volume was unmounted.
    let volumeDidUnmount: HostNotification

    package init(
        appDidBecomeActive: HostNotification, systemWillSleep: HostNotification, systemDidWake: HostNotification,
        volumeDidMount: HostNotification, volumeDidUnmount: HostNotification
    ) {
        self.appDidBecomeActive = appDidBecomeActive
        self.systemWillSleep = systemWillSleep
        self.systemDidWake = systemDidWake
        self.volumeDidMount = volumeDidMount
        self.volumeDidUnmount = volumeDidUnmount
    }
}
