import AppKit

/// Hosts the app-wide Settings window (⌘,).
///
/// A single instance is retained by `AppDelegate` and reused across opens. The
/// content is a toolbar-style `SettingsTabViewController`; the window is
/// non-resizable, matching the platform convention for settings.
@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(contentViewController: SettingsTabViewController())
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setFrameAutosaveName("KernovaSettings")
        self.init(window: window)
    }
}
