import Cocoa
import os
import SwiftUI

/// Manages the main library window using an `NSSplitViewController` for sidebar/detail layout
/// and an `NSToolbar` with native toolbar items. SwiftUI views render content inside each pane.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {

    private let viewModel: VMLibraryViewModel
    private let splitViewController = NSSplitViewController()
    private let sidebarItem: NSSplitViewItem
    private var observingToolbar = false
    private var sidebarCollapseObservation: NSKeyValueObservation?

    private static let logger = Logger(subsystem: "com.kernova.app", category: "MainWindowController")

    private enum LifecycleSegment: Int {
        case play = 0, pause = 1, stop = 2

        static let startToolTip = "Start the virtual machine"
        static let resumeToolTip = "Resume the virtual machine"
        static let pauseToolTip = "Pause the virtual machine"
        static let stopToolTip = "Stop the virtual machine"
    }

    // MARK: - Toolbar Item Identifiers

    private static let toolbarNewVM = NSToolbarItem.Identifier("newVM")
    private static let toolbarLifecycle = NSToolbarItem.Identifier("lifecycle")
    private static let toolbarSaveState = NSToolbarItem.Identifier("saveState")
    private static let saveStateToolTip = "Save the virtual machine state to disk"
    private static let toolbarDisplay = NSToolbarItem.Identifier("display")

    private enum DisplaySegment: Int {
        case popOut = 0, fullscreen = 1

        static let popOutToolTip = "Open display in a separate window"
        static let popInToolTip = "Return display to the main window"
        static let fullscreenToolTip = "Enter fullscreen display"
        static let exitFullscreenToolTip = "Exit fullscreen display"
    }

    // MARK: - Init

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel

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

        updateLifecycleGroup(in: toolbar)
        updateSaveStateItem(in: toolbar)
        updateDisplayGroup(in: toolbar)
    }

    private func updateLifecycleGroup(in toolbar: NSToolbar) {
        guard let group = toolbar.items.first(where: { $0.itemIdentifier == Self.toolbarLifecycle }) as? NSToolbarItemGroup,
              group.subitems.count == 3 else {
            Self.logger.warning("updateLifecycleGroup: lifecycle group missing or has unexpected subitem count")
            return
        }

        guard let instance = viewModel.selectedInstance, !instance.isPreparing else {
            group.subitems.forEach { $0.isEnabled = false }
            return
        }

        let canResume = instance.status.canResume
        let playLabel = canResume ? "Resume" : "Start"

        let play = group.subitems[LifecycleSegment.play.rawValue]
        if play.label != playLabel {
            play.label = playLabel
            play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: playLabel)
            play.toolTip = canResume ? LifecycleSegment.resumeToolTip : LifecycleSegment.startToolTip
        }

        play.isEnabled = instance.status.canStart || canResume
        group.subitems[LifecycleSegment.pause.rawValue].isEnabled = instance.status.canPause
        group.subitems[LifecycleSegment.stop.rawValue].isEnabled = instance.canStop || instance.isColdPaused
    }

    private func updateSaveStateItem(in toolbar: NSToolbar) {
        guard let group = toolbar.items.first(where: { $0.itemIdentifier == Self.toolbarSaveState }) as? NSToolbarItemGroup,
              let subitem = group.subitems.first else {
            Self.logger.warning("updateSaveStateItem: save state group missing or empty")
            return
        }
        guard let instance = viewModel.selectedInstance, !instance.isPreparing else {
            subitem.isEnabled = false
            return
        }
        subitem.isEnabled = instance.canSave
    }

    private func updateDisplayGroup(in toolbar: NSToolbar) {
        guard let group = toolbar.items.first(where: { $0.itemIdentifier == Self.toolbarDisplay }) as? NSToolbarItemGroup,
              group.subitems.count == 2 else {
            Self.logger.warning("updateDisplayGroup: display group missing or has unexpected subitem count")
            return
        }

        let popOutItem = group.subitems[DisplaySegment.popOut.rawValue]
        let fullscreenItem = group.subitems[DisplaySegment.fullscreen.rawValue]

        guard let instance = viewModel.selectedInstance, !instance.isPreparing else {
            popOutItem.isEnabled = false
            fullscreenItem.isEnabled = false
            return
        }

        let canUse = instance.canUseExternalDisplay
        popOutItem.isEnabled = canUse
        fullscreenItem.isEnabled = canUse

        let popLabel = instance.isInSeparateWindow ? "Pop In" : "Pop Out"
        if popOutItem.label != popLabel {
            popOutItem.label = popLabel
            popOutItem.image = NSImage(
                systemSymbolName: instance.isInSeparateWindow ? "pip.enter" : "pip.exit",
                accessibilityDescription: popLabel
            )
            popOutItem.toolTip = instance.isInSeparateWindow
                ? DisplaySegment.popInToolTip
                : DisplaySegment.popOutToolTip
        }

        let fsLabel = instance.isInFullscreen ? "Exit Fullscreen" : "Fullscreen"
        if fullscreenItem.label != fsLabel {
            fullscreenItem.label = fsLabel
            fullscreenItem.image = NSImage(
                systemSymbolName: instance.isInFullscreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                accessibilityDescription: fsLabel
            )
            fullscreenItem.toolTip = instance.isInFullscreen
                ? DisplaySegment.exitFullscreenToolTip
                : DisplaySegment.fullscreenToolTip
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            Self.toolbarNewVM,
            .toggleSidebar,
            .sidebarTrackingSeparator,
            Self.toolbarLifecycle,
            Self.toolbarSaveState,
            Self.toolbarDisplay,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.toolbarNewVM,
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            Self.toolbarLifecycle,
            Self.toolbarSaveState,
            Self.toolbarDisplay,
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

        case Self.toolbarLifecycle:
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: [
                    NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Start")!,
                    NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")!,
                    NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")!,
                ],
                selectionMode: .momentary,
                labels: ["Start", "Pause", "Stop"],
                target: self,
                action: #selector(lifecycleAction(_:))
            )
            group.label = "State Controls"
            group.subitems[LifecycleSegment.play.rawValue].toolTip = LifecycleSegment.startToolTip
            group.subitems[LifecycleSegment.pause.rawValue].toolTip = LifecycleSegment.pauseToolTip
            group.subitems[LifecycleSegment.stop.rawValue].toolTip = LifecycleSegment.stopToolTip
            group.autovalidates = false
            return group

        case Self.toolbarSaveState:
            return makeSingleItemGroup(
                identifier: itemIdentifier,
                label: "Save State",
                symbol: "square.and.arrow.down",
                action: #selector(AppDelegate.saveVM(_:)),
                toolTip: Self.saveStateToolTip
            )

        case Self.toolbarDisplay:
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: [
                    NSImage(systemSymbolName: "pip.exit", accessibilityDescription: "Pop Out")!,
                    NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Fullscreen")!,
                ],
                selectionMode: .momentary,
                labels: ["Pop Out", "Fullscreen"],
                target: self,
                action: #selector(displayAction(_:))
            )
            group.label = "Display"
            group.subitems[DisplaySegment.popOut.rawValue].toolTip = DisplaySegment.popOutToolTip
            group.subitems[DisplaySegment.fullscreen.rawValue].toolTip = DisplaySegment.fullscreenToolTip
            group.autovalidates = false
            return group

        default:
            return nil
        }
    }

    // MARK: - Lifecycle Group Action

    @objc private func lifecycleAction(_ group: NSToolbarItemGroup) {
        guard let segment = LifecycleSegment(rawValue: group.selectedIndex) else {
            Self.logger.warning("lifecycleAction: unexpected selectedIndex \(group.selectedIndex)")
            return
        }
        switch segment {
        case .play:
            if viewModel.selectedInstance?.status.canResume ?? false {
                NSApp.sendAction(#selector(AppDelegate.resumeVM(_:)), to: nil, from: nil)
            } else {
                NSApp.sendAction(#selector(AppDelegate.startVM(_:)), to: nil, from: nil)
            }
        case .pause:
            NSApp.sendAction(#selector(AppDelegate.pauseVM(_:)), to: nil, from: nil)
        case .stop:
            NSApp.sendAction(#selector(AppDelegate.stopVM(_:)), to: nil, from: nil)
        }
    }

    // MARK: - Display Group Action

    @objc private func displayAction(_ group: NSToolbarItemGroup) {
        guard let segment = DisplaySegment(rawValue: group.selectedIndex) else {
            Self.logger.warning("displayAction: unexpected selectedIndex \(group.selectedIndex)")
            return
        }
        switch segment {
        case .popOut:
            NSApp.sendAction(#selector(AppDelegate.togglePopOut(_:)), to: nil, from: nil)
        case .fullscreen:
            NSApp.sendAction(#selector(AppDelegate.toggleFullscreen(_:)), to: nil, from: nil)
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

    private func makeSingleItemGroup(
        identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector,
        toolTip: String? = nil
    ) -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(
            itemIdentifier: identifier,
            images: [NSImage(systemSymbolName: symbol, accessibilityDescription: label)!],
            selectionMode: .momentary,
            labels: [label],
            target: nil,
            action: action
        )
        group.label = label
        if let toolTip { group.subitems.first?.toolTip = toolTip }
        group.autovalidates = false
        return group
    }
}

// MARK: - NSToolbarItemValidation

extension MainWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let instance = viewModel.selectedInstance, !instance.isPreparing else {
            return item.itemIdentifier == Self.toolbarNewVM
        }

        switch item.itemIdentifier {
        case Self.toolbarNewVM, Self.toolbarLifecycle, Self.toolbarSaveState, Self.toolbarDisplay:
            // Group subitems are enabled/disabled directly in updateToolbarItems()
            return true
        default:
            Self.logger.debug("validateToolbarItem: unrecognized identifier '\(item.itemIdentifier.rawValue)'")
            return true
        }
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
