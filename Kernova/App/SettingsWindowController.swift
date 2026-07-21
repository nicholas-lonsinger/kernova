import AppKit

/// Hosts the app-wide Settings window (⌘,).
///
/// A single instance is retained by `AppDelegate` and reused across opens. The
/// content is a toolbar-style `SettingsTabViewController`; the window is
/// non-resizable, matching the platform convention for settings.
@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init(viewModel: VMLibraryViewModel) {
        // RATIONALE: deliberately *not* `NSWindow.withStableContentSize`, which the
        // main and clipboard windows use. That factory pins a fixed initial content
        // size, and this window has no single correct one — it is non-resizable and
        // its height is whatever the selected pane publishes as `preferredContentSize`,
        // re-applied by `SettingsTabViewController` on appear and on every tab switch.
        // The plain initializer's fitting-size behavior is what we want here; the
        // factory's flexible-content collapse (a split view's minimum thicknesses) has
        // no analogue in a fixed-width settings pane.
        let window = NSWindow(
            contentViewController: SettingsTabViewController(viewModel: viewModel))
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        // The controller is a singleton reused across opens, so the window must
        // survive being closed (don't deallocate it out from under the reference).
        window.isReleasedWhenClosed = false
        // RATIONALE: the autosaved frame is kept for its *position* only — a saved
        // frame also restores a height, which for this non-resizable window is stale
        // the moment the pane list or a pane's content changes (#629: it stretched the
        // first pane's cards over the excess). AppKit has no position-only autosave, so
        // `SettingsTabViewController` re-asserts the height on appear instead; losing
        // the remembered position would be the worse trade.
        window.setFrameAutosaveName("KernovaSettings")
        self.init(window: window)
    }
}
