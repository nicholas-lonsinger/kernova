import AppKit

/// Hosts the Check Config Files window: a window of its own rather than a
/// sheet, because Settings, the library window and a launch with no window
/// all open it, and Use Defaults reloads the library a sheet would sit on.
///
/// A single instance is retained by `AppWindowRegistry` and reused across
/// opens; every open checks the files again.
@MainActor
final class ConfigCheckWindowController: NSWindowController {
    private let checkViewController: ConfigCheckViewController

    init(viewModel: VMLibraryViewModel, autosaveScope: WindowAutosaveScope) {
        let checkViewController = ConfigCheckViewController(viewModel: viewModel)
        self.checkViewController = checkViewController
        let window = NSWindow.withStableContentSize(
            NSSize(width: 620, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            contentViewController: checkViewController)
        window.title = "Check Config Files"
        window.contentMinSize = NSSize(width: 480, height: 300)
        // Reused across opens, so the window must survive being closed.
        window.isReleasedWhenClosed = false
        // Centered first, so a saved frame the autosave name restores wins.
        window.center()
        window.setFrameAutosaveName(autosaveScope.configCheckFrame)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConfigCheckWindowController does not support NSCoder")
    }

    /// Brings the window forward and checks every config file again.
    func showAndCheck() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        checkViewController.runCheck()
    }
}
