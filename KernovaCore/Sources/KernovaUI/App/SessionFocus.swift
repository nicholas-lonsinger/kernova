import AppKit
import KernovaCore

/// How a window goes on screen.
package enum WindowPresentation: Equatable {
    /// In front of the app's other windows, and key.
    case keyAndFront
    /// In front of the app's other windows, leaving key where it is.
    case front
    /// Behind every other window at its level.
    case back
    /// In front whether or not the app is active.
    case frontRegardless
}

/// The login session's focus as Kernova reads and changes it: the app's
/// activation, activation policy (whether it has a Dock icon) and hidden
/// state; the windows the window registry, display placement, residency and
/// alert presenter put on screen, and how each goes there; the key and main
/// window; how a window stands on screen; and the events that change these.
///
/// Sheets, alerts, popovers and open and save panels go on screen and become
/// key through AppKit, outside this type; so do AppKit's own dispatch of an
/// action along the responder chain and a view's key-window emphasis.
///
/// Apart from those, the one instance the composition root builds is the only
/// way the app's code changes its activation, activation policy or hidden
/// state, or puts a window on screen or makes it key, and the only way it reads
/// that state and the key and main window; the window registry and alert
/// presenter also read a window's standing and the events that change it
/// through it. A test host that builds its own stand-in therefore never reaches
/// the session through it.
@MainActor
package protocol SessionFocus: AnyObject {
    var activationPolicy: NSApplication.ActivationPolicy { get }
    /// Sets the activation policy; does nothing when already at `policy`.
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
    /// Notifications posted when a window becomes key or main or is
    /// deminiaturized, the app is unhidden, or the active Space changes.
    var focusChanged: [HostNotification] { get }
}
