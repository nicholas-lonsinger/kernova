import AppKit
import KernovaCore

/// How a window goes on screen.
package enum WindowPresentation: Equatable {
    /// In front of the app's other windows, and key.
    case keyAndFront
    /// In front of the app's other windows, leaving key where it is.
    case front
    /// Behind the app's other windows.
    case back
    /// In front whether or not the app is active.
    case frontRegardless
}

/// The login session's focus as Kernova meets it: its activation policy
/// (whether it has a Dock icon), whether it is hidden and frontmost, every
/// window Kernova puts on screen, and which window has the keyboard.
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

    func present(_ window: NSWindow, _ presentation: WindowPresentation)
    /// Enters or leaves native fullscreen.
    func toggleFullScreenMode(of window: NSWindow)
    /// The standard About panel.
    func showAboutPanel(options: [NSApplication.AboutPanelOptionKey: Any])
    /// Ends whatever menu-bar tracking is in progress.
    func cancelMenuBarTracking()

    /// The window that takes keyboard input.
    var keyWindow: NSWindow? { get }
    /// The window a menu action falls back to when the key window doesn't
    /// take it.
    var mainWindow: NSWindow? { get }
    /// How `window` stands on screen.
    func standing(of window: NSWindow) -> WindowStanding
    /// Post when a window becomes key or main or is deminiaturized, the app is
    /// unhidden, or the active Space changes.
    var focusChanged: [HostNotification] { get }
}
