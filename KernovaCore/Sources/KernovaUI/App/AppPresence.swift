import AppKit

/// The process-wide `NSApplication` state through which Kernova meets the
/// desktop: its activation policy (whether it has a Dock icon), whether it is
/// hidden, and whether it is frontmost.
///
/// Every read and change of that state goes through the one instance the
/// composition root builds, so a test host that builds its own stand-in never
/// reaches the desktop.
@MainActor
package protocol AppPresence: AnyObject {
    var activationPolicy: NSApplication.ActivationPolicy { get }
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy)

    /// Whether Kernova is the active app.
    var isActive: Bool { get }
    /// Asks for activation; a no-op while the app is already active.
    func activate()

    /// Whether the app is hidden.
    var isHidden: Bool { get }
    /// Leaves the hidden state without asking for activation.
    func unhideWithoutActivation()
}

/// ``AppPresence`` over `NSApp`.
@MainActor
package final class SystemAppPresence: AppPresence {
    package init() {}

    package var activationPolicy: NSApplication.ActivationPolicy { NSApp.activationPolicy() }

    package func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        NSApp.setActivationPolicy(policy)
    }

    package var isActive: Bool { NSApp.isActive }

    package func activate() {
        guard !NSApp.isActive else { return }
        NSApp.activate()
    }

    package var isHidden: Bool { NSApp.isHidden }

    package func unhideWithoutActivation() {
        NSApp.unhideWithoutActivation()
    }
}
