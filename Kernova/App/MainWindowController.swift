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
    private var sidebarCollapseObservation: NSKeyValueObservation?

    private static let logger = Logger(subsystem: "com.kernova.app", category: "MainWindowController")

    private enum LifecycleSegment: Int {
        case play = 0, pause = 1, stop = 2
    }

    // MARK: - Toolbar Item Identifiers

    private static let toolbarNewVM = NSToolbarItem.Identifier("newVM")
    private static let toolbarLifecycle = NSToolbarItem.Identifier("lifecycle")
    private static let toolbarSaveState = NSToolbarItem.Identifier("saveState")
    private static let toolbarFullscreen = NSToolbarItem.Identifier("fullscreen")

    // MARK: - Init

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel

        let sidebarHost = NSHostingController(rootView: SidebarView(viewModel: viewModel))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 350
        splitViewController.addSplitViewItem(sidebarItem)

        let detailHost = NSHostingController(rootView: MainDetailView(viewModel: viewModel))
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

        // Restore saved frame BEFORE enabling autosave to avoid overwriting it.
        // Only center on first launch (when no saved frame exists).
        if !window.setFrameUsingName("KernovaMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("KernovaMainWindow")

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
        let sidebarItem = splitViewController.splitViewItems[0]
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
        let isCollapsed = splitViewController.splitViewItems[0].isCollapsed
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

        updateLifecycleGroup(in: toolbar)
        updateFullscreenItem(in: toolbar)
        toolbar.validateVisibleItems()
    }

    private func updateLifecycleGroup(in toolbar: NSToolbar) {
        guard let group = toolbar.items.first(where: { $0.itemIdentifier == Self.toolbarLifecycle }) as? NSToolbarItemGroup,
              group.subitems.count == 3 else { return }

        let instance = viewModel.selectedInstance
        let allDisabled = instance == nil || (instance?.isPreparing ?? false)
        let canResume = instance?.status.canResume ?? false
        let playLabel = canResume ? "Resume" : "Start"

        let play = group.subitems[LifecycleSegment.play.rawValue]
        if play.label != playLabel {
            play.label = playLabel
            play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: playLabel)
        }

        play.isEnabled = !allDisabled && ((instance?.status.canStart ?? false) || canResume)
        group.subitems[LifecycleSegment.pause.rawValue].isEnabled = !allDisabled && (instance?.status.canPause ?? false)
        group.subitems[LifecycleSegment.stop.rawValue].isEnabled = !allDisabled && (instance?.status.canStop ?? false)
    }

    private func updateFullscreenItem(in toolbar: NSToolbar) {
        guard let group = toolbar.items.first(where: { $0.itemIdentifier == Self.toolbarFullscreen }) as? NSToolbarItemGroup,
              let subitem = group.subitems.first else { return }
        let isFullscreen = viewModel.selectedInstance?.isInFullscreen ?? false
        let label = isFullscreen ? "Exit Fullscreen" : "Fullscreen"
        if subitem.label != label {
            subitem.label = label
            group.label = label
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
            Self.toolbarFullscreen,
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
            group.label = "Controls"
            return group

        case Self.toolbarSaveState:
            return makeSingleItemGroup(
                identifier: itemIdentifier,
                label: "Save State",
                symbol: "square.and.arrow.down",
                action: #selector(AppDelegate.saveVM(_:))
            )

        case Self.toolbarFullscreen:
            return makeSingleItemGroup(
                identifier: itemIdentifier,
                label: "Fullscreen",
                symbol: "arrow.up.left.and.arrow.down.right",
                action: #selector(AppDelegate.toggleFullscreenDisplay(_:))
            )

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
        action: Selector
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
        case Self.toolbarNewVM, Self.toolbarLifecycle:
            return true
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
