import Cocoa
import os

/// Manages the main library window using an `NSSplitViewController` for sidebar/detail layout
/// and an `NSToolbar` with native toolbar items.
///
/// AppKit view controllers render content inside each pane.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    private let viewModel: VMLibraryViewModel
    private let toolbarManager: VMToolbarManager
    private let splitViewController = SnapToFitSplitViewController()
    private let sidebarViewController: SidebarViewController
    private let sidebarItem: NSSplitViewItem
    private var sidebarCollapseObservation: NSKeyValueObservation?
    private var toolbarObservation: ObservationLoop?

    private static let logger = Logger(subsystem: "app.kernova", category: "MainWindowController")
    private static let toolbarNewVM = NSToolbarItem.Identifier("newVM")

    // MARK: - Init

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
        self.toolbarManager = VMToolbarManager(
            configuration: .init(
                lifecycleID: NSToolbarItem.Identifier("lifecycle"),
                saveStateID: NSToolbarItem.Identifier("saveState"),
                clipboardID: NSToolbarItem.Identifier("clipboard"),
                displayID: NSToolbarItem.Identifier("display"),
                settingsToggleID: NSToolbarItem.Identifier("settingsToggle"),
                checksPreparing: true,
                gatesDisplayOnCapability: true
            ),
            instanceProvider: { [weak viewModel] in viewModel?.selectedInstance }
        )

        let sidebarVC = SidebarViewController(viewModel: viewModel)
        self.sidebarViewController = sidebarVC
        self.sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 212
        sidebarItem.maximumThickness = 400
        splitViewController.addSplitViewItem(sidebarItem)

        let detailContainer = DetailContainerViewController(viewModel: viewModel)
        let detailItem = NSSplitViewItem(viewController: detailContainer)
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
        // First-run default; once customization autosave kicks in, the saved
        // configuration (restored when the toolbar is attached to the window)
        // overrides this, so all properties must be set before the attach below.
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.setFrameAutosaveName("KernovaMainWindow")

        // Finder-style snap: while dragging the divider, magnetize it to the
        // width that fully shows the longest VM name, clamped to the sidebar's
        // min/max thickness. The closure reports the width the *outline view*
        // needs plus its current width; the split controller converts that to a
        // divider position (they differ by fixed divider chrome) and clamps.
        splitViewController.sidebarMetrics = { [weak self] in
            guard let self, let needed = self.sidebarViewController.widthToFitLongestRow() else {
                return nil
            }
            return SidebarSnapMetrics(
                neededOutlineWidth: needed,
                currentOutlineWidth: self.sidebarViewController.currentOutlineWidth,
                minThickness: self.sidebarItem.minimumThickness,
                maxThickness: self.sidebarItem.maximumThickness
            )
        }

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

    /// Uncollapses the sidebar so a command that targets it (the menu bar's
    /// Rename) lands on a visible surface.
    func revealSidebar() {
        guard sidebarItem.isCollapsed else { return }
        sidebarItem.animator().isCollapsed = false
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
        // RATIONALE: isHidden rather than insertItem/removeItem — programmatic
        // structural edits would be captured by the toolbar's autosaved
        // configuration and would fight a user-customized layout (the old code
        // re-inserted at a hardcoded index). A hidden item stays in the user's
        // layout untouched; if the user removed New VM via customization the
        // lookup misses and there is nothing to do.
        guard let item = toolbar.items.first(where: { $0.itemIdentifier == Self.toolbarNewVM }) else {
            return
        }
        item.isHidden = sidebarItem.isCollapsed
    }

    // MARK: - Toolbar State Observation

    private func observeToolbarState() {
        toolbarObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.viewModel.selectedID
                _ = self.viewModel.selectedInstance?.status
                _ = self.viewModel.selectedInstance?.isPreparing
                _ = self.viewModel.selectedInstance?.displayMode
                _ = self.viewModel.selectedInstance?.virtualMachine
                _ = self.viewModel.selectedInstance?.configuration.clipboardSharingEnabled
                _ = self.viewModel.selectedInstance?.detailPaneMode
            },
            apply: { [weak self] in
                self?.updateToolbarItems()
            }
        )
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
            .space,
            .flexibleSpace,
        ] + toolbarManager.sharedItemIdentifiers
    }

    /// Pins the sidebar region — toggle and tracking separator — the way Mail and
    /// Notes do; everything else is user-customizable.
    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        [.toggleSidebar, .sidebarTrackingSeparator]
    }

    func toolbarWillAddItem(_ notification: Notification) {
        // A palette-added item is born with factory-default labels and enablement
        // (autovalidates is false on the shared items), and during will-add it is
        // not yet in toolbar.items — refresh one runloop turn later so it
        // immediately reflects VM state and sidebar collapse.
        Task { @MainActor [weak self] in
            self?.updateToolbarItems()
            self?.updateNewVMToolbarVisibility()
        }
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
        item.image = .systemSymbol(symbol, accessibilityDescription: label)
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
            || toolbarManager.sharedItemIdentifiers.contains(item.itemIdentifier)
        {
            // Group subitems are enabled/disabled directly in updateToolbarItems()
            return true
        }

        Self.logger.debug(
            "validateToolbarItem: unrecognized identifier '\(item.itemIdentifier.rawValue, privacy: .public)'")
        return true
    }
}

// MARK: - Snap-to-fit split view controller

/// `NSSplitViewController` that magnetizes the sidebar divider to a caller-
/// supplied "fit" width during a drag, the way Finder snaps its sidebar to the
/// width of the longest item.
///
/// The sidebar's hard min/max thickness is still enforced by the split view
/// item; this only adds a soft snap point in between. `sidebarMetrics` returns
/// the outline geometry to snap to, or `nil` when there's nothing to snap to.
/// Live sidebar geometry the snap controller needs to convert a "fit the
/// longest name" outline width into a divider position.
struct SidebarSnapMetrics {
    /// Outline width at which the longest VM name is fully visible.
    let neededOutlineWidth: CGFloat
    /// The outline view's current width (to derive the divider→outline offset).
    let currentOutlineWidth: CGFloat
    /// The sidebar's hard min/max thickness, clamping the snap target.
    let minThickness: CGFloat
    let maxThickness: CGFloat
}

@MainActor
final class SnapToFitSplitViewController: NSSplitViewController {
    /// Sidebar geometry needed to compute the snap, or `nil` to disable it.
    var sidebarMetrics: (() -> SidebarSnapMetrics?)?

    /// How close (in points) the drag must come to the fit width before it snaps.
    private static let snapThreshold: CGFloat = 10

    override func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0, let metrics = sidebarMetrics?(),
            let sidebarItem = splitViewItems.first
        else { return proposedPosition }

        // `proposedPosition` is a divider coordinate; the sidebar's content
        // (the outline) is inset a few points from the pane's trailing edge, so
        // the snap target must be expressed as a pane width, not an outline
        // width. Find the sidebar's arranged subview (a direct child of the
        // split view — a sidebar item may wrap its content) and use its trailing
        // edge as the live divider position, against the outline's current
        // width. The view controller's own `view.frame` is in its wrapper's
        // coordinates, so walk up to the split view's child.
        var arranged: NSView? = sidebarItem.viewController.view
        while let view = arranged, view.superview !== splitView { arranged = view.superview }
        let dividerNow = arranged?.frame.maxX ?? proposedPosition
        let offset = max(0, dividerNow - metrics.currentOutlineWidth)
        let target = min(
            max(metrics.neededOutlineWidth + offset, metrics.minThickness), metrics.maxThickness)

        guard abs(proposedPosition - target) <= Self.snapThreshold else { return proposedPosition }
        return target
    }
}
