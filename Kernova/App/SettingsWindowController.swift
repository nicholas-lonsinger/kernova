import AppKit

/// Hosts the app-wide Settings window (⌘,).
///
/// A single instance is retained by `AppDelegate` and reused across opens. The
/// content is a toolbar-style `SettingsTabViewController`; the window is
/// non-resizable, matching the platform convention for settings.
@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init(viewModel: VMLibraryViewModel) {
        let window = NSWindow(
            contentViewController: SettingsTabViewController(viewModel: viewModel))
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        // The controller is a singleton reused across opens, so the window must
        // survive being closed (don't deallocate it out from under the reference).
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("KernovaSettings")
        self.init(window: window)
    }
}
