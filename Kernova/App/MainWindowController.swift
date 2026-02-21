import Cocoa
import SwiftUI

/// Hosts the main UI using `NSSplitViewController` with separate sidebar and detail panes.
/// Using AppKit-level split view enables full-height sidebar layout (sidebar extends behind title bar).
/// Toolbar is managed via `NSToolbarDelegate` because SwiftUI `.toolbar` modifiers don't propagate
/// from `NSHostingController` children of `NSSplitViewController` to the window's toolbar.
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSGestureRecognizerDelegate {

    private var viewModel: VMLibraryViewModel!
    private var sidebarHostingController: NSViewController?

    // MARK: - Toolbar Item Identifiers

    private static let newVMIdentifier = NSToolbarItem.Identifier("newVM")
    private static let startVMIdentifier = NSToolbarItem.Identifier("startVM")
    private static let pauseVMIdentifier = NSToolbarItem.Identifier("pauseVM")
    private static let resumeVMIdentifier = NSToolbarItem.Identifier("resumeVM")
    private static let stopVMIdentifier = NSToolbarItem.Identifier("stopVM")
    private static let saveVMIdentifier = NSToolbarItem.Identifier("saveVM")
    private static let deleteVMIdentifier = NSToolbarItem.Identifier("deleteVM")
    private static let fullscreenVMIdentifier = NSToolbarItem.Identifier("fullscreenVM")

    /// All possible action identifiers, used for reference.
    private static let allActionIdentifiers: Set<NSToolbarItem.Identifier> = [
        startVMIdentifier, pauseVMIdentifier, resumeVMIdentifier,
        stopVMIdentifier, saveVMIdentifier, deleteVMIdentifier,
        fullscreenVMIdentifier,
    ]

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
        window.minSize = NSSize(width: 800, height: 500)

        self.init(window: window)
        self.viewModel = viewModel
        self.sidebarHostingController = sidebarHosting
        self.shouldCascadeWindows = false

        // Toolbar — managed via NSToolbarDelegate since SwiftUI toolbar propagation
        // doesn't work through NSSplitViewController child hosting controllers.
        // Set up before frame restore since toolbar affects window geometry.
        let toolbar = NSToolbar(identifier: "KernovaMainToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // Restore saved frame BEFORE enabling autosave to avoid overwriting it.
        // Only center on first launch (when no saved frame exists).
        if !window.setFrameUsingName("KernovaMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("KernovaMainWindow")

        // Deselect sidebar row when clicking empty space below the VM list
        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(sidebarEmptyAreaClicked(_:)))
        clickGesture.delegate = self
        sidebarHosting.view.addGestureRecognizer(clickGesture)

        observeToolbarState()
    }

    // MARK: - Sidebar Empty-Area Click

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard let sidebarView = sidebarHostingController?.view,
              let tableView = findTableView(in: sidebarView) else {
            return false
        }
        let point = gestureRecognizer.location(in: tableView)
        return tableView.row(at: point) == -1
    }

    @objc private func sidebarEmptyAreaClicked(_ sender: NSClickGestureRecognizer) {
        viewModel.selectedID = nil
    }

    private func findTableView(in view: NSView) -> NSTableView? {
        if let tableView = view as? NSTableView { return tableView }
        for subview in view.subviews {
            if let found = findTableView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Toolbar State Observation

    /// Tracks both the selected instance and its status to dynamically rebuild
    /// action toolbar items whenever either changes.
    private func observeToolbarState() {
        withObservationTracking {
            _ = self.viewModel.selectedInstance
            _ = self.viewModel.selectedInstance?.status
            _ = self.viewModel.selectedInstance?.virtualMachine
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rebuildActionItems()
                self.observeToolbarState()
            }
        }
    }

    /// Removes existing action items and spacer, then re-inserts individual
    /// bordered `NSToolbarItem`s after a `.space` separator following the "+" button.
    private func rebuildActionItems() {
        guard let toolbar = window?.toolbar else { return }

        // Remove existing action items and any .space we inserted
        for index in stride(from: toolbar.items.count - 1, through: 0, by: -1) {
            let id = toolbar.items[index].itemIdentifier
            if Self.allActionIdentifiers.contains(id) || id == .space {
                toolbar.removeItem(at: index)
            }
        }

        guard let instance = viewModel.selectedInstance else { return }

        let desiredIdentifiers = desiredActionIdentifiers(for: instance)
        guard !desiredIdentifiers.isEmpty else { return }

        // Insert a spacer after the "+" button to break the pill grouping
        var insertIndex = (toolbar.items.firstIndex {
            $0.itemIdentifier == Self.newVMIdentifier
        } ?? toolbar.items.count - 1) + 1

        toolbar.insertItem(withItemIdentifier: .space, at: insertIndex)
        insertIndex += 1

        for identifier in desiredIdentifiers {
            toolbar.insertItem(withItemIdentifier: identifier, at: insertIndex)
            insertIndex += 1
        }
    }

    /// Returns the action identifiers that should be visible for a given VM instance.
    private func desiredActionIdentifiers(for instance: VMInstance) -> [NSToolbarItem.Identifier] {
        switch instance.status {
        case .stopped:
            return [Self.startVMIdentifier, Self.deleteVMIdentifier]
        case .running:
            return [Self.pauseVMIdentifier, Self.stopVMIdentifier, Self.saveVMIdentifier, Self.fullscreenVMIdentifier]
        case .paused:
            if instance.isColdPaused {
                // State already saved to disk — no Save State, offer Delete instead
                return [Self.resumeVMIdentifier, Self.stopVMIdentifier, Self.deleteVMIdentifier]
            }
            return [Self.resumeVMIdentifier, Self.stopVMIdentifier, Self.saveVMIdentifier]
        case .error:
            return [Self.startVMIdentifier, Self.deleteVMIdentifier]
        case .starting, .saving, .restoring, .installing:
            return []
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            Self.newVMIdentifier,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            .space,
            .toggleSidebar,
            .sidebarTrackingSeparator,
            Self.newVMIdentifier,
            Self.startVMIdentifier,
            Self.pauseVMIdentifier,
            Self.resumeVMIdentifier,
            Self.stopVMIdentifier,
            Self.saveVMIdentifier,
            Self.deleteVMIdentifier,
            Self.fullscreenVMIdentifier,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == Self.newVMIdentifier {
            return makeNewVMItem()
        }
        if Self.allActionIdentifiers.contains(itemIdentifier) {
            return makeActionItem(for: itemIdentifier)
        }
        return nil
    }

    // MARK: - Toolbar Item Construction

    private func makeNewVMItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.newVMIdentifier)
        item.label = "New VM"
        item.paletteLabel = "New VM"
        item.toolTip = "Create a new virtual machine"
        item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New VM")
        item.isBordered = true
        item.target = nil
        item.action = #selector(AppDelegate.newVM(_:))
        return item
    }

    // MARK: - Action Button Specs

    private struct ActionButtonSpec {
        let symbolName: String
        let toolTip: String
        let accessibilityLabel: String
        let action: Selector
    }

    private func actionButtonSpec(for identifier: NSToolbarItem.Identifier) -> ActionButtonSpec? {
        switch identifier {
        case Self.startVMIdentifier:
            return ActionButtonSpec(
                symbolName: "play.fill", toolTip: "Start this virtual machine",
                accessibilityLabel: "Start", action: #selector(AppDelegate.startVM(_:)))
        case Self.pauseVMIdentifier:
            return ActionButtonSpec(
                symbolName: "pause.fill", toolTip: "Pause the virtual machine",
                accessibilityLabel: "Pause", action: #selector(AppDelegate.pauseVM(_:)))
        case Self.resumeVMIdentifier:
            return ActionButtonSpec(
                symbolName: "play.fill", toolTip: "Resume the virtual machine",
                accessibilityLabel: "Resume", action: #selector(AppDelegate.resumeVM(_:)))
        case Self.stopVMIdentifier:
            return ActionButtonSpec(
                symbolName: "stop.fill", toolTip: "Stop the virtual machine",
                accessibilityLabel: "Stop", action: #selector(AppDelegate.stopVM(_:)))
        case Self.saveVMIdentifier:
            return ActionButtonSpec(
                symbolName: "square.and.arrow.down", toolTip: "Save the virtual machine state to disk",
                accessibilityLabel: "Save State", action: #selector(AppDelegate.saveVM(_:)))
        case Self.deleteVMIdentifier:
            return ActionButtonSpec(
                symbolName: "trash", toolTip: "Move this virtual machine to the Trash",
                accessibilityLabel: "Move to Trash", action: #selector(AppDelegate.deleteVM(_:)))
        case Self.fullscreenVMIdentifier:
            return ActionButtonSpec(
                symbolName: "arrow.up.left.and.arrow.down.right", toolTip: "Enter fullscreen display",
                accessibilityLabel: "Fullscreen", action: #selector(AppDelegate.toggleFullscreenDisplay(_:)))
        default:
            return nil
        }
    }

    private func makeActionItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard let spec = actionButtonSpec(for: identifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = spec.accessibilityLabel
        item.paletteLabel = spec.accessibilityLabel
        item.toolTip = spec.toolTip
        item.image = NSImage(systemSymbolName: spec.symbolName, accessibilityDescription: spec.accessibilityLabel)
        item.isBordered = true
        item.target = nil
        item.action = spec.action
        return item
    }
}
