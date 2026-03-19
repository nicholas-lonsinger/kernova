import Cocoa
import SwiftUI

/// Hosts the main UI using SwiftUI's `NavigationSplitView` inside a single `NSHostingController`.
/// An empty `NSToolbar` with `.unified` style is attached so that SwiftUI `.toolbar` modifiers
/// populate it automatically, while `.fullSizeContentView` preserves the full-height sidebar look.
final class MainWindowController: NSWindowController {

    convenience init(viewModel: VMLibraryViewModel) {
        let hostingController = NSHostingController(rootView: ContentView(viewModel: viewModel))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "Kernova"
        window.minSize = NSSize(width: 800, height: 500)

        self.init(window: window)
        self.shouldCascadeWindows = false

        // Empty toolbar — SwiftUI .toolbar modifiers populate it automatically
        let toolbar = NSToolbar(identifier: "KernovaMainToolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // Restore saved frame BEFORE enabling autosave to avoid overwriting it.
        // Only center on first launch (when no saved frame exists).
        if !window.setFrameUsingName("KernovaMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("KernovaMainWindow")
    }

    /// Makes the window visible behind other windows without stealing focus.
    func showWindowInBackground() {
        window?.orderBack(nil)
    }
}
