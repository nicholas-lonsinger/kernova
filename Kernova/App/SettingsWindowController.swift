import AppKit

/// Hosts the app-wide Settings window (⌘,).
///
/// A single instance is retained by `AppWindowRegistry` and reused across opens. The
/// content is a toolbar-style `SettingsTabViewController`; the window is
/// non-resizable, matching the platform convention for settings.
@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init(viewModel: VMLibraryViewModel, autosaveScope: WindowAutosaveScope) {
        // `NSWindow.withStableContentSize` pins a fixed initial content size, and
        // this window has none: its height is whatever the selected pane publishes
        // as `preferredContentSize`, re-applied by `SettingsTabViewController` on
        // every tab switch.
        let window = NSWindow(
            contentViewController: SettingsTabViewController(viewModel: viewModel))
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        // The controller is a singleton reused across opens, so the window must
        // survive being closed (don't deallocate it out from under the reference).
        window.isReleasedWhenClosed = false
        // A saved frame also restores a height, which for this non-resizable window
        // goes stale when the pane list or a pane's content changes (observed
        // stretching the first pane's cards over the excess). AppKit has no
        // position-only autosave, so `SettingsTabViewController` re-asserts the
        // height on appear.
        window.setFrameAutosaveName(autosaveScope.settingsFrame)
        self.init(window: window)
    }
}
