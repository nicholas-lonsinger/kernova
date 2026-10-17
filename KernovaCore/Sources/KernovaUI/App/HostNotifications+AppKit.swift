import AppKit
import KernovaCore

extension HostNotifications {
    /// The host's notifications as AppKit posts them: app activation on the
    /// default center, sleep, wake and volume changes on `NSWorkspace`'s.
    @MainActor
    package static func appKit() -> HostNotifications {
        let workspace = NSWorkspace.shared.notificationCenter
        return HostNotifications(
            appDidBecomeActive: HostNotification(
                center: .default, name: NSApplication.didBecomeActiveNotification),
            systemWillSleep: HostNotification(
                center: workspace, name: NSWorkspace.willSleepNotification),
            systemDidWake: HostNotification(center: workspace, name: NSWorkspace.didWakeNotification),
            volumeDidMount: HostNotification(
                center: workspace, name: NSWorkspace.didMountNotification),
            volumeDidUnmount: HostNotification(
                center: workspace, name: NSWorkspace.didUnmountNotification))
    }
}
