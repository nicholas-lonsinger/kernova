import AppKit
import KernovaTestSupport

@testable import KernovaCore
@testable import KernovaUI

/// Stands in for the login session's focus, so no test changes the test host's
/// Dock presence, asks for the front, or makes a window key.
///
/// Holds the state a test gives it, and records every request in order. A
/// presented window is ordered in behind the rest, where a stage window stays
/// beyond every display, and one presented key reads as key while it is
/// visible and the app reads as active — AppKit's key and main window can be
/// `nil` while the app is inactive. Nothing else a request asks for is
/// performed: `activate()` leaves ``isActive`` as given, as AppKit grants
/// activation, if at all, after the request returns.
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

    var activationPolicy: NSApplication.ActivationPolicy
    let isActive: Bool
    /// Held across an unhide, so every presentation that would unhide records
    /// its own request.
    let isHidden: Bool
    private(set) var requests: [Request] = []
    /// Notified after each request is recorded.
    let gate = AsyncGate()
    /// Runs inside each request, once it is recorded — where AppKit would act
    /// on it.
    var onRequest: (Request) -> Void = { _ in }

    private weak var recordedKeyWindow: NSWindow?
    private weak var recordedMainWindow: NSWindow?
    private let miniaturized = NSHashTable<NSWindow>.weakObjects()
    private let center = NotificationCenter()
    private let changed = Notification.Name("RecordingSessionFocus.focusChanged")

    init(
        activationPolicy: NSApplication.ActivationPolicy = .regular, isActive: Bool = false,
        isHidden: Bool = false
    ) {
        self.activationPolicy = activationPolicy
        self.isActive = isActive
        self.isHidden = isHidden
    }

    private func record(_ request: Request) {
        requests.append(request)
        onRequest(request)
        gate.notify()
    }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        activationPolicy = policy
        record(.setActivationPolicy(policy))
    }

    func activate() { record(.activate) }

    func unhideWithoutActivation() { record(.unhideWithoutActivation) }

    func present(_ window: NSWindow, _ presentation: WindowPresentation) {
        window.orderBack(nil)
        miniaturized.remove(window)
        if presentation == .keyAndFront {
            recordedKeyWindow = window
            if window.canBecomeMain { recordedMainWindow = window }
        }
        record(.present(window, presentation))
        if presentation == .keyAndFront { postFocusChanged() }
    }

    func toggleFullScreenMode(of window: NSWindow) { record(.toggleFullScreenMode(window)) }

    func showAboutPanel(options: [NSApplication.AboutPanelOptionKey: Any]) { record(.showAboutPanel) }

    func cancelMenuBarTracking() { record(.cancelMenuBarTracking) }

    var keyWindow: NSWindow? { onScreenWhileActive(recordedKeyWindow) }

    var mainWindow: NSWindow? { onScreenWhileActive(recordedMainWindow) }

    private func onScreenWhileActive(_ window: NSWindow?) -> NSWindow? {
        guard isActive, let window, window.isVisible else { return nil }
        return window
    }

    func standing(of window: NSWindow) -> WindowStanding {
        WindowStanding(
            isVisible: window.isVisible, isMiniaturized: miniaturized.contains(window), isOnActiveSpace: true)
    }

    var focusChanged: [HostNotification] { [HostNotification(center: center, name: changed)] }

    /// The user miniaturizing `window`: it leaves the screen and reads as
    /// miniaturized until it is presented again.
    func minimize(_ window: NSWindow) {
        window.orderOut(nil)
        miniaturized.add(window)
        postFocusChanged()
    }

    private func postFocusChanged() {
        center.post(name: changed, object: nil)
    }
}
