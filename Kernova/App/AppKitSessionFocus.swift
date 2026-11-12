import AppKit
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
}
