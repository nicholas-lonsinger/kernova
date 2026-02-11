import Cocoa
import SwiftUI

/// Hosts the main UI using `NSSplitViewController` with separate sidebar and detail panes.
/// Using AppKit-level split view enables full-height sidebar layout (sidebar extends behind title bar).
final class MainWindowController: NSWindowController {

    convenience init(viewModel: VMLibraryViewModel) {
        // Sidebar pane
        let sidebarHosting = NSHostingController(rootView: SidebarView(viewModel: viewModel))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHosting)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 350

        // Detail pane
        let detailHosting = NSHostingController(rootView: ContentView(viewModel: viewModel))
        let detailItem = NSSplitViewItem(viewController: detailHosting)
        detailItem.minimumThickness = 400

        // Split view controller
        let splitVC = NSSplitViewController()
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(detailItem)
        splitVC.splitView.autosaveName = "KernovaSidebar"

        // Window — .fullSizeContentView lets sidebar extend behind the title bar
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = splitVC
        window.title = "Kernova"
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.minSize = NSSize(width: 800, height: 500)
        window.center()
        window.setFrameAutosaveName("KernovaMainWindow")

        // Toolbar — SwiftUI .toolbar items propagate via the responder chain
        let toolbar = NSToolbar(identifier: "KernovaMainToolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        self.init(window: window)
    }
}
