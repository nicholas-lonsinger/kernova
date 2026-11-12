import AppKit
import KernovaCore

/// Hosts the app-wide Settings window (⌘,).
///
/// A single instance is retained by `AppWindowRegistry` and reused across opens. The
/// content is a toolbar-style `SettingsTabViewController`; the window is
/// non-resizable, matching the platform convention for settings.
@MainActor
final class SettingsWindowController: NSWindowController {
    let tabs: SettingsTabViewController

    init(viewModel: VMLibraryViewModel, stage: WindowStage) {
        let tabs = SettingsTabViewController(viewModel: viewModel, visibleFrame: stage.visibleFrame)
        // `WindowStage.makeWindow(stableContentSize:…)` pins a fixed initial
        // content size, and this window has none: its height is whatever the
        // selected pane publishes as `preferredContentSize`, re-applied by
        // `SettingsTabViewController` on every tab switch.
        let window = stage.makeContentWindow(tabs)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.autorecalculatesKeyViewLoop = true
        // The controller is a singleton reused across opens, so the window must
        // survive being closed (don't deallocate it out from under the reference).
        window.isReleasedWhenClosed = false
        self.tabs = tabs
        super.init(window: window)
        // The saved frame restores the top-left at the window's current,
        // provisional height; `prepareToShow(at:)` gives it the pane's height.
        windowFrameAutosaveName = stage.autosave.settingsFrame
    }

    /// Readies the window to go on screen: on `destination`, or on the pane it
    /// was last left on when `nil`, at that pane's height.
    func prepareToShow(at destination: SettingsDestination?) {
        if let destination { tabs.show(destination) }
        tabs.prepareToShow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController does not support NSCoder")
    }
}
