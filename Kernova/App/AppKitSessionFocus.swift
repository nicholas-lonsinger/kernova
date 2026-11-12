import AppKit
import KernovaCore
import KernovaLogging
import KernovaUI

/// ``SessionFocus`` over `NSApp`.
@MainActor
final class AppKitSessionFocus: SessionFocus {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "SessionFocus")

    var activationPolicy: NSApplication.ActivationPolicy { NSApp.activationPolicy() }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        let current = NSApp.activationPolicy()
        guard current != policy else { return }
        NSApp.setActivationPolicy(policy)
        Self.logger.log(
            .notice, "Activation policy \(current.rawValue, privacy: .public) → \(policy.rawValue, privacy: .public)")
    }

    var isActive: Bool { NSApp.isActive }

    func activate() {
        guard !NSApp.isActive else { return }
        NSApp.activate()
    }

    var isHidden: Bool { NSApp.isHidden }

    func unhideWithoutActivation() {
        NSApp.unhideWithoutActivation()
    }

    func present(_ window: NSWindow, _ presentation: WindowPresentation) {
        switch presentation {
        case .keyAndFront: window.makeKeyAndOrderFront(nil)
        case .front: window.orderFront(nil)
        case .back: window.orderBack(nil)
        case .frontRegardless: window.orderFrontRegardless()
        }
    }

    func toggleFullScreenMode(of window: NSWindow) {
        window.toggleFullScreen(nil)
    }

    func showAboutPanel(options: [NSApplication.AboutPanelOptionKey: Any]) {
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    func cancelMenuBarTracking() {
        NSApp.mainMenu?.cancelTracking()
    }

    var keyWindow: NSWindow? { NSApp.keyWindow }

    var mainWindow: NSWindow? { NSApp.mainWindow }

    func standing(of window: NSWindow) -> WindowStanding {
        WindowStanding(
            isVisible: window.isVisible, isMiniaturized: window.isMiniaturized,
            isOnActiveSpace: window.isOnActiveSpace)
    }

    let focusChanged: [HostNotification] =
        [
            NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
            NSWindow.didDeminiaturizeNotification, NSApplication.didUnhideNotification,
        ].map { HostNotification(center: .default, name: $0) }
        + [
            HostNotification(
                center: NSWorkspace.shared.notificationCenter, name: NSWorkspace.activeSpaceDidChangeNotification)
        ]
}
