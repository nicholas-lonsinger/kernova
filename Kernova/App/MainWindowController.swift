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

    /// All VM action identifiers in their canonical toolbar order.
    private static let actionIdentifiers: [NSToolbarItem.Identifier] = [
        startVMIdentifier,
        pauseVMIdentifier,
        resumeVMIdentifier,
        stopVMIdentifier,
        saveVMIdentifier,
        deleteVMIdentifier,
    ]

    private static let actionIdentifierSet: Set<NSToolbarItem.Identifier> = Set(actionIdentifiers)

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

        self.init(window: window)
        self.viewModel = viewModel
        self.sidebarHostingController = sidebarHosting

        // Toolbar — managed via NSToolbarDelegate since SwiftUI toolbar propagation
        // doesn't work through NSSplitViewController child hosting controllers.
        let toolbar = NSToolbar(identifier: "KernovaMainToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        window.toolbar = toolbar
        window.toolbarStyle = .unified

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
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rebuildActionItems()
                self.observeToolbarState()
            }
        }
    }

    /// Removes all current action items and re-inserts the appropriate ones
    /// based on the selected VM's status.
    private func rebuildActionItems() {
        guard let toolbar = window?.toolbar else { return }

        // Remove existing action items (iterate in reverse to keep indices stable)
        for index in stride(from: toolbar.items.count - 1, through: 0, by: -1) {
            if Self.actionIdentifierSet.contains(toolbar.items[index].itemIdentifier) {
                toolbar.removeItem(at: index)
            }
        }

        guard let instance = viewModel.selectedInstance else { return }

        // Determine which items to show based on current status
        let desiredIdentifiers = desiredActionIdentifiers(for: instance.status)

        // Insert each before the "+" (newVM) item
        let newVMIndex = toolbar.items.firstIndex {
            $0.itemIdentifier == Self.newVMIdentifier
        } ?? toolbar.items.count

        for (offset, identifier) in desiredIdentifiers.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: newVMIndex + offset)
        }
    }

    /// Returns the action identifiers that should be visible for a given VM status.
    private func desiredActionIdentifiers(for status: VMStatus) -> [NSToolbarItem.Identifier] {
        switch status {
        case .stopped:
            return [Self.startVMIdentifier, Self.deleteVMIdentifier]
        case .running:
            return [Self.pauseVMIdentifier, Self.stopVMIdentifier, Self.saveVMIdentifier]
        case .paused:
            return [Self.resumeVMIdentifier, Self.stopVMIdentifier, Self.saveVMIdentifier]
        case .error:
            return [Self.deleteVMIdentifier]
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
            .toggleSidebar,
            .sidebarTrackingSeparator,
            Self.startVMIdentifier,
            Self.pauseVMIdentifier,
            Self.resumeVMIdentifier,
            Self.stopVMIdentifier,
            Self.saveVMIdentifier,
            Self.deleteVMIdentifier,
            Self.newVMIdentifier,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.newVMIdentifier:
            return makeNewVMItem()
        case Self.startVMIdentifier:
            return makeStartVMItem()
        case Self.pauseVMIdentifier:
            return makePauseVMItem()
        case Self.resumeVMIdentifier:
            return makeResumeVMItem()
        case Self.stopVMIdentifier:
            return makeStopVMItem()
        case Self.saveVMIdentifier:
            return makeSaveVMItem()
        case Self.deleteVMIdentifier:
            return makeDeleteVMItem()
        default:
            return nil
        }
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

    private func makeStartVMItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.startVMIdentifier)
        item.label = "Start"
        item.paletteLabel = "Start VM"
        item.toolTip = "Start this virtual machine"
        item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Start")
        item.isBordered = true
        item.target = nil
        item.action = #selector(AppDelegate.startVM(_:))
        return item
    }

    private func makePauseVMItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.pauseVMIdentifier)
        item.label = "Pause"
        item.paletteLabel = "Pause VM"
        item.toolTip = "Pause the virtual machine"
        item.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
        item.isBordered = true
        item.target = nil
        item.action = #selector(AppDelegate.pauseVM(_:))
        return item
    }

    private func makeResumeVMItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.resumeVMIdentifier)
        item.label = "Resume"
        item.paletteLabel = "Resume VM"
        item.toolTip = "Resume the virtual machine"
        item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Resume")
        item.isBordered = true
        item.target = nil
        item.action = #selector(AppDelegate.resumeVM(_:))
        return item
    }

    private func makeStopVMItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.stopVMIdentifier)
        item.label = "Stop"
        item.paletteLabel = "Stop VM"
        item.toolTip = "Stop the virtual machine"
        item.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")
        item.isBordered = true
        item.target = nil
        item.action = #selector(AppDelegate.stopVM(_:))
        return item
    }

    private func makeSaveVMItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.saveVMIdentifier)
        item.label = "Save State"
        item.paletteLabel = "Save VM State"
        item.toolTip = "Save the virtual machine state to disk"
        item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save State")
        item.isBordered = true
        item.target = nil
        item.action = #selector(AppDelegate.saveVM(_:))
        return item
    }

    private func makeDeleteVMItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.deleteVMIdentifier)
        item.label = "Delete"
        item.paletteLabel = "Delete VM"
        item.toolTip = "Delete this virtual machine"
        item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
        item.isBordered = true
        item.target = nil
        item.action = #selector(AppDelegate.deleteVM(_:))
        return item
    }
}
