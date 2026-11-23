import AppKit

@testable import KernovaCore
@testable import KernovaUI

/// Stands in for the login session's focus, so no test changes the test host's
/// Dock presence, asks for the front, or makes a window key.
///
/// The app reads as inactive and not hidden, and every request is recorded in
/// order. A presented window is ordered in behind the rest, where a stage
/// window stays beyond every display; AppKit's key and main window are `nil`
/// while the app is inactive. Nothing else a request asks for is performed:
/// `activate()` leaves ``isActive`` as it was, as AppKit grants activation, if
/// at all, after the request returns.
@MainActor
final class RecordingSessionFocus: SessionFocus {
    enum Request: Equatable {
        case setActivationPolicy(NSApplication.ActivationPolicy)
        case activate
        case unhideWithoutActivation
        case present(NSWindow, WindowPresentation)
        case toggleFullScreenMode(NSWindow)
        case showAboutPanel
        case cancelMenuBarTracking
    }

    private(set) var activationPolicy: NSApplication.ActivationPolicy = .regular
    let isActive = false
    let isHidden = false
    private(set) var requests: [Request] = []

    private let center = NotificationCenter()
    private let changed = Notification.Name("RecordingSessionFocus.focusChanged")

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard policy != activationPolicy else { return }
        activationPolicy = policy
        requests.append(.setActivationPolicy(policy))
    }

    func activate() { requests.append(.activate) }

    func unhideWithoutActivation() { requests.append(.unhideWithoutActivation) }

    func present(_ window: NSWindow, _ presentation: WindowPresentation) {
        window.orderBack(nil)
        requests.append(.present(window, presentation))
        if presentation == .keyAndFront { center.post(name: changed, object: nil) }
    }

    func toggleFullScreenMode(of window: NSWindow) { requests.append(.toggleFullScreenMode(window)) }

    func showAboutPanel(options: [NSApplication.AboutPanelOptionKey: Any]) { requests.append(.showAboutPanel) }

    func cancelMenuBarTracking() { requests.append(.cancelMenuBarTracking) }

    var keyWindow: NSWindow? { nil }

    var mainWindow: NSWindow? { nil }

    func standing(of window: NSWindow) -> WindowStanding {
        WindowStanding(isVisible: window.isVisible, isMiniaturized: false, isOnActiveSpace: true)
    }

    var focusChanged: [HostNotification] { [HostNotification(center: center, name: changed)] }
}
