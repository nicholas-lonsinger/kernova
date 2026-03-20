import Cocoa
import os
import SwiftUI

/// Manages the main library window using an `NSSplitViewController` for sidebar/detail layout
/// and an `NSToolbar` with native toolbar items. SwiftUI views render content inside each pane.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {

    private let viewModel: VMLibraryViewModel
    private let splitViewController = NSSplitViewController()
    private var observingToolbar = false

    private static let logger = Logger(subsystem: "com.kernova.app", category: "MainWindowController")

    // MARK: - Toolbar Item Identifiers

    private static let toolbarNewVM = NSToolbarItem.Identifier("newVM")
    private static let toolbarPlay = NSToolbarItem.Identifier("play")
    private static let toolbarPause = NSToolbarItem.Identifier("pause")
    private static let toolbarStop = NSToolbarItem.Identifier("stop")
    private static let toolbarSaveState = NSToolbarItem.Identifier("saveState")
    private static let toolbarFullscreen = NSToolbarItem.Identifier("fullscreen")

    // MARK: - Init

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel

        // Sidebar pane
        let sidebarHost = NSHostingController(rootView: SidebarView(viewModel: viewModel))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 350
        splitViewController.addSplitViewItem(sidebarItem)

        // Detail pane
        let detailHost = NSHostingController(rootView: MainDetailView(viewModel: viewModel))
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = 400
        splitViewController.addSplitViewItem(detailItem)

        splitViewController.splitView.autosaveName = "KernovaMainSplit"

        // Window
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

        // Toolbar
        let toolbar = NSToolbar(identifier: "KernovaMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // Restore saved frame BEFORE enabling autosave to avoid overwriting it.
        // Only center on first launch (when no saved frame exists).
        if !window.setFrameUsingName("KernovaMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("KernovaMainWindow")

        observeToolbarState()
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

    // MARK: - Toolbar State Observation

    private func observeToolbarState() {
        observingToolbar = true
        withObservationTracking {
            _ = self.viewModel.selectedID
            _ = self.viewModel.selectedInstance?.status
            _ = self.viewModel.selectedInstance?.isPreparing
            _ = self.viewModel.selectedInstance?.isInFullscreen
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

        updatePlayItem(in: toolbar)
        updateFullscreenItem(in: toolbar)
        toolbar.validateVisibleItems()
    }

    private func updatePlayItem(in toolbar: NSToolbar) {
        guard let playItem = toolbar.items.first(where: { $0.itemIdentifier == Self.toolbarPlay }) else { return }
        let canResume = viewModel.selectedInstance?.status.canResume ?? false
        let label = canResume ? "Resume" : "Start"
        playItem.label = label
        playItem.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: label)
        playItem.toolTip = canResume ? "Resume the virtual machine" : "Start this virtual machine"
        playItem.action = canResume ? #selector(AppDelegate.resumeVM(_:)) : #selector(AppDelegate.startVM(_:))
    }

    private func updateFullscreenItem(in toolbar: NSToolbar) {
        guard let fullscreenItem = toolbar.items.first(where: { $0.itemIdentifier == Self.toolbarFullscreen }) else { return }
        let isFullscreen = viewModel.selectedInstance?.isInFullscreen ?? false
        fullscreenItem.label = isFullscreen ? "Exit Fullscreen" : "Fullscreen"
        fullscreenItem.toolTip = isFullscreen ? "Exit fullscreen display" : "Enter fullscreen display"
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.toolbarNewVM,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            Self.toolbarPlay,
            Self.toolbarPause,
            Self.toolbarStop,
            .space,
            Self.toolbarSaveState,
            .space,
            Self.toolbarFullscreen,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.toolbarNewVM,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            .space,
            Self.toolbarPlay,
            Self.toolbarPause,
            Self.toolbarStop,
            Self.toolbarSaveState,
            Self.toolbarFullscreen,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.toolbarNewVM:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "New VM",
                symbol: "plus",
                action: #selector(AppDelegate.newVM(_:)),
                toolTip: "Create a new virtual machine"
            )

        case Self.toolbarPlay:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "Start",
                symbol: "play.fill",
                action: #selector(AppDelegate.startVM(_:)),
                toolTip: "Start this virtual machine"
            )

        case Self.toolbarPause:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "Pause",
                symbol: "pause.fill",
                action: #selector(AppDelegate.pauseVM(_:)),
                toolTip: "Pause the virtual machine"
            )

        case Self.toolbarStop:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Stop"
            item.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")
            item.action = #selector(AppDelegate.stopVM(_:))
            item.toolTip = "Stop the virtual machine. Click and hold for Force Stop."
            item.isBordered = true
            item.showsIndicator = false
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Force Stop", action: #selector(AppDelegate.forceStopVM(_:)), keyEquivalent: ""))
            item.menu = menu
            return item

        case Self.toolbarSaveState:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "Save State",
                symbol: "square.and.arrow.down",
                action: #selector(AppDelegate.saveVM(_:)),
                toolTip: "Save the virtual machine state to disk"
            )

        case Self.toolbarFullscreen:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "Fullscreen",
                symbol: "arrow.up.left.and.arrow.down.right",
                action: #selector(AppDelegate.toggleFullscreenDisplay(_:)),
                toolTip: "Enter fullscreen display"
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

        switch item.itemIdentifier {
        case Self.toolbarNewVM:
            return true
        case Self.toolbarPlay:
            // Update action based on current state since canResume may have changed
            let canResume = instance.status.canResume
            item.action = canResume ? #selector(AppDelegate.resumeVM(_:)) : #selector(AppDelegate.startVM(_:))
            return instance.status.canStart || canResume
        case Self.toolbarPause:
            return instance.status.canPause
        case Self.toolbarStop:
            return instance.status.canStop || instance.status.canForceStop
        case Self.toolbarSaveState:
            return instance.canSave
        case Self.toolbarFullscreen:
            return instance.canFullscreen
        default:
            Self.logger.debug("validateToolbarItem: unrecognized identifier '\(item.itemIdentifier.rawValue)'")
            return true
        }
    }
}
