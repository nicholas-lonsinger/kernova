import Cocoa
import os
import SwiftUI

/// Manages the main library window using an `NSSplitViewController` for sidebar/detail layout
/// and an `NSToolbar` with native toolbar items. SwiftUI views render content inside each pane.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {

    private let viewModel: VMLibraryViewModel
    private let toolbarManager: VMToolbarManager
    private let splitViewController = NSSplitViewController()
    private let sidebarItem: NSSplitViewItem
    private var observingToolbar = false
    private var sidebarCollapseObservation: NSKeyValueObservation?

    private static let logger = Logger(subsystem: "com.kernova.app", category: "MainWindowController")
    private static let toolbarNewVM = NSToolbarItem.Identifier("newVM")

    // MARK: - Init

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
        self.toolbarManager = VMToolbarManager(
            configuration: .init(
                lifecycleID: NSToolbarItem.Identifier("lifecycle"),
                saveStateID: NSToolbarItem.Identifier("saveState"),
                displayID: NSToolbarItem.Identifier("display"),
                checksPreparing: true,
                gatesDisplayOnCapability: true
            ),
            instanceProvider: { [weak viewModel] in viewModel?.selectedInstance }
        )

        let sidebarHost = NSHostingController(rootView: SidebarView(viewModel: viewModel))
        sidebarHost.sizingOptions = []
        self.sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 350
        splitViewController.addSplitViewItem(sidebarItem)

        let detailHost = NSHostingController(rootView: MainDetailView(viewModel: viewModel))
        detailHost.sizingOptions = []
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = 400
        splitViewController.addSplitViewItem(detailItem)

        splitViewController.splitView.autosaveName = "KernovaMainSplit"

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = splitViewController
        window.title = "Kernova"
        window.minSize = NSSize(width: 800, height: 500)

        super.init(window: window)
        window.delegate = self
        self.shouldCascadeWindows = false

        let toolbar = NSToolbar(identifier: "KernovaMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.restoreFrame(named: "KernovaMainWindow")

        updateToolbarItems()
        observeToolbarState()
        observeSidebarCollapse()
        Self.logger.notice("Main window controller initialized")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Makes the window visible behind other windows without stealing focus.
    func showWindowInBackground() {
        window?.orderBack(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        observingToolbar = false
        Self.logger.debug("Main window closing, toolbar observation stopped")
    }

    // MARK: - Sidebar Collapse Observation

    private func observeSidebarCollapse() {
        let sidebarItem = sidebarItem
        sidebarCollapseObservation = sidebarItem.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.updateNewVMToolbarVisibility()
            }
        }
    }

    private func updateNewVMToolbarVisibility() {
        guard let toolbar = window?.toolbar else {
            Self.logger.warning("updateNewVMToolbarVisibility: window or toolbar is nil — skipping update")
            return
        }
        let isCollapsed = sidebarItem.isCollapsed
        let currentIndex = toolbar.items.firstIndex { $0.itemIdentifier == Self.toolbarNewVM }

        if isCollapsed, let index = currentIndex {
            toolbar.removeItem(at: index)
        } else if !isCollapsed, currentIndex == nil {
            // Insert after the leading flexible space
            toolbar.insertItem(withItemIdentifier: Self.toolbarNewVM, at: 1)
        }
    }

    // MARK: - Toolbar State Observation

    private func observeToolbarState() {
        observingToolbar = true
        withObservationTracking {
            _ = self.viewModel.selectedID
            _ = self.viewModel.selectedInstance?.status
            _ = self.viewModel.selectedInstance?.isPreparing
            _ = self.viewModel.selectedInstance?.displayMode
            _ = self.viewModel.selectedInstance?.virtualMachine
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.observingToolbar else { return }
                self.updateToolbarItems()
                self.observeToolbarState()
            }
        }
    }

    private func updateToolbarItems() {
        guard let toolbar = window?.toolbar else {
            Self.logger.warning("updateToolbarItems: window or toolbar is nil — toolbar state will be stale")
            return
        }

        toolbarManager.updateToolbarItems(in: toolbar)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            Self.toolbarNewVM,
            .toggleSidebar,
            .sidebarTrackingSeparator,
        ] + toolbarManager.sharedItemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.toolbarNewVM,
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .flexibleSpace,
        ] + toolbarManager.sharedItemIdentifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if let sharedItem = toolbarManager.makeToolbarItem(for: itemIdentifier) {
            return sharedItem
        }

        switch itemIdentifier {
        case Self.toolbarNewVM:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "New VM",
                symbol: "plus",
                action: #selector(AppDelegate.newVM(_:)),
                toolTip: "Create a new virtual machine"
            )
        default:
            return nil
        }
    }

    // MARK: - Toolbar Item Factory

    private func makeToolbarItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector,
        toolTip: String
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
        item.toolTip = toolTip
        item.isBordered = true
        return item
    }

}

// MARK: - NSToolbarItemValidation

extension MainWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let instance = viewModel.selectedInstance, !instance.isPreparing else {
            return item.itemIdentifier == Self.toolbarNewVM
        }

        if item.itemIdentifier == Self.toolbarNewVM
            || toolbarManager.sharedItemIdentifiers.contains(item.itemIdentifier) {
            // Group subitems are enabled/disabled directly in updateToolbarItems()
            return true
        }

        Self.logger.debug("validateToolbarItem: unrecognized identifier '\(item.itemIdentifier.rawValue)'")
        return true
    }
}

// MARK: - NSWindow Frame Restoration

extension NSWindow {
    private static let frameLogger = Logger(subsystem: "com.kernova.app", category: "NSWindow+FrameRestore")

    /// Restores a previously saved frame, validates it's visible on a connected screen,
    /// and enables autosave for future changes. Centers the window if no saved frame exists
    /// or the saved frame doesn't intersect any connected screen.
    func restoreFrame(named name: String) {
        if !setFrameUsingName(name) {
            center()
        }
        let screens = NSScreen.screens
        if !screens.isEmpty, !screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            Self.frameLogger.warning("Restored frame for '\(name)' is off-screen, centering window")
            center()
        }
        setFrameAutosaveName(name)
    }
}
