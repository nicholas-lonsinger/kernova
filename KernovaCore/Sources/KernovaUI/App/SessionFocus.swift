import AppKit

/// The login session's focus as Kernova meets it: its activation policy
/// (whether it has a Dock icon), whether it is hidden, and whether it is
/// frontmost.
///
/// Every read and change of that state goes through the one instance the
/// composition root builds, so a test host that builds its own stand-in never
/// reaches the session.
@MainActor
package protocol SessionFocus: AnyObject {
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
