import AppKit
import KernovaTestSupport

@testable import KernovaUI

/// Stands in for the login session's focus, so no test changes the test host's
/// Dock presence, asks for the front, or makes a window key.
///
/// Holds the state a test gives it, and records every request in order. A
/// presented window is ordered in behind the rest, where a stage window stays
/// beyond every display; nothing else a request asks for is performed.
@MainActor
final class RecordingSessionFocus: SessionFocus {
    enum Request: Equatable {
        case setActivationPolicy(NSApplication.ActivationPolicy)
        case activate
        case unhideWithoutActivation
        case present(NSWindow, WindowPresentation)
        case toggleFullScreen(NSWindow)
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
        record(.present(window, presentation))
    }

    func toggleFullScreen(_ window: NSWindow) { record(.toggleFullScreen(window)) }

    func showAboutPanel(options: [NSApplication.AboutPanelOptionKey: Any]) { record(.showAboutPanel) }

    func cancelMenuBarTracking() { record(.cancelMenuBarTracking) }
}
