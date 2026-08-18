import Cocoa
import os

/// Manages the main library window using an `NSSplitViewController` for sidebar/detail layout
/// and an `NSToolbar` with native toolbar items.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    private let viewModel: VMLibraryViewModel
    private let preferences: AppPreferences
    private let toolbarManager: VMToolbarManager
    private let splitViewController = SnapToFitSplitViewController()
    private let sidebarViewController: SidebarViewController
    private let sidebarItem: NSSplitViewItem
    /// The detail pane, retained so the display-boot geometry of the inline
    /// display can be measured.
    let detailContainer: DetailContainerViewController
    private var windowStateObservation: ObservationLoop?
    private var sidebarCollapseObservation: NSKeyValueObservation?
    /// The toolbar index New VM was programmatically removed from for a
    /// collapsed sidebar, or `nil` when it is in the toolbar (or the user
    /// removed it themselves via customization).
    private var newVMCollapseRemovalIndex: Int? {
        didSet { preferences.mainToolbarNewVMCollapseIndex = newVMCollapseRemovalIndex }
    }
    private var sheetIsCustomizationPalette = false

    private static let logger = Logger(subsystem: "app.kernova", category: "MainWindowController")
    private static let toolbarNewVM = NSToolbarItem.Identifier("newVM")

    // Palette-only items (offered in the customize sheet, not in the default
    // set). VM-scoped verbs only — app-global commands like "Open VMs Folder"
    // stay menu-bar-only.
    private static let toolbarClone = NSToolbarItem.Identifier("cloneVM")
    private static let toolbarShowInFinder = NSToolbarItem.Identifier("showInFinder")
    private static let toolbarMoveToTrash = NSToolbarItem.Identifier("moveToTrash")

    // MARK: - Init

    init(viewModel: VMLibraryViewModel, preferences: AppPreferences = .shared) {
        self.viewModel = viewModel
        self.preferences = preferences
        self.toolbarManager = VMToolbarManager(
            configuration: .init(
                lifecycleID: NSToolbarItem.Identifier("lifecycle"),
                saveStateID: NSToolbarItem.Identifier("saveState"),
                clipboardID: NSToolbarItem.Identifier("clipboard"),
                popOutID: NSToolbarItem.Identifier("popOut"),
                fullscreenID: NSToolbarItem.Identifier("fullscreen"),
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
        self.detailContainer = detailContainer
        let detailItem = NSSplitViewItem(viewController: detailContainer)
        detailItem.minimumThickness = 400
        splitViewController.addSplitViewItem(detailItem)

        splitViewController.splitView.autosaveName = "KernovaMainSplit"

        let window = NSWindow.withStableContentSize(
            NSSize(width: 1200, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            contentViewController: splitViewController
        )
        // First-launch position; a saved frame restored by setFrameAutosaveName
        // below overrides both the size and this placement.
        window.center()
        window.title = "Kernova"
        // Order matters: assigning `contentViewController` resizes the window to the
        // content view's fitting size, and `minSize` then clamps to that. Setting
        // `minSize` first lets the fitting size overwrite it.
        window.minSize = NSSize(width: 800, height: 500)

        super.init(window: window)
        window.delegate = self
        self.shouldCascadeWindows = false

        let toolbar = NSToolbar(identifier: "KernovaMainToolbar")
        toolbar.delegate = self
        // The autosaved configuration is restored when the toolbar is attached to
        // the window, so every property must be set before the attach below.
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.setFrameAutosaveName("KernovaMainWindow")

        // Finder-style snap: while dragging the divider, magnetize it to the
        // width that fully shows the longest VM name.
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
        updateWindowTitle()
        observeWindowState()
        adoptPersistedNewVMRemoval()
        observeSidebarCollapse()
        Self.logger.notice("Main window controller initialized")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindowInBackground() {
        window?.orderBack(nil)
    }

    /// Uncollapses the sidebar so a command that targets it (the menu bar's
    /// Rename) lands on a visible surface.
    func revealSidebar() {
        guard sidebarItem.isCollapsed else { return }
        sidebarItem.animator().isCollapsed = false
    }

    // MARK: - Window State Observation

    private func observeWindowState() {
        windowStateObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.viewModel.selectedID
                _ = self.viewModel.selectedInstance?.name
                _ = self.viewModel.selectedInstance?.status
                _ = self.viewModel.selectedInstance?.isPreparing
                _ = self.viewModel.selectedInstance?.displayMode
                _ = self.viewModel.selectedInstance?.hasLiveVirtualMachine
                _ = self.viewModel.selectedInstance?.configuration.clipboardSharingEnabled
                _ = self.viewModel.selectedInstance?.detailPaneMode
            },
            apply: { [weak self] in
                self?.updateToolbarItems()
                self?.updateWindowTitle()
            }
        )
    }

    // MARK: - Sidebar-Collapse New VM Visibility

    /// Hides New VM while the sidebar is collapsed and restores it on expand.
    ///
    /// Implemented as remove/insert rather than `NSToolbarItem.isHidden`: on
    /// the glass toolbar a hidden item's slot keeps its width (measured on
    /// macOS 27 beta 4), leaving a dead gap between the window controls and
    /// the sidebar toggle, while removal reclaims the space.
    private func observeSidebarCollapse() {
        sidebarCollapseObservation = sidebarItem.observe(\.isCollapsed, options: [.initial]) {
            [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.syncNewVMVisibilityToSidebarState()
            }
        }
    }

    private func syncNewVMVisibilityToSidebarState() {
        guard let toolbar = window?.toolbar, !toolbar.customizationPaletteIsRunning else { return }
        if sidebarItem.isCollapsed {
            guard newVMCollapseRemovalIndex == nil,
                let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.toolbarNewVM }),
                let separatorIndex = toolbar.items.firstIndex(where: {
                    $0.itemIdentifier == .sidebarTrackingSeparator
                }),
                index < separatorIndex
            else { return }
            // The collapsed toolbar is a transient presentation, not a
            // customization, so the removal stays out of the saved layout.
            withAutosaveSuspended(toolbar) { toolbar.removeItem(at: index) }
            newVMCollapseRemovalIndex = index
        } else if let index = newVMCollapseRemovalIndex {
            restoreNewVMItem(in: toolbar, at: index)
        }
    }

    /// Reinstates a collapse-removed New VM at the slot it came from.
    ///
    /// The index is clamped because a ⌘-drag move while the sidebar is collapsed
    /// has no AppKit hook to keep it current. The insert deliberately runs with
    /// autosave *live*: it returns the toolbar to the user's canonical layout,
    /// which is exactly what should be persisted.
    private func restoreNewVMItem(in toolbar: NSToolbar, at index: Int) {
        newVMCollapseRemovalIndex = nil
        guard !toolbar.items.contains(where: { $0.itemIdentifier == Self.toolbarNewVM }) else {
            return
        }
        toolbar.insertItem(
            withItemIdentifier: Self.toolbarNewVM,
            at: min(max(index, 0), toolbar.items.count)
        )
    }

    /// Re-adopts a collapse removal that outlived the process, so New VM is
    /// never stranded out of the toolbar for good.
    ///
    /// `withAutosaveSuspended` keeps *our* mutation out of the saved layout, but
    /// an autosave triggered by anything else while New VM is out (View ▸ Hide
    /// Toolbar, a display-mode change) persists the New-VM-less item list, and
    /// the next launch cannot tell that removal from a deliberate one. Adopted
    /// only when New VM really is absent.
    private func adoptPersistedNewVMRemoval() {
        guard let index = preferences.mainToolbarNewVMCollapseIndex,
            let toolbar = window?.toolbar,
            !toolbar.items.contains(where: { $0.itemIdentifier == Self.toolbarNewVM })
        else {
            newVMCollapseRemovalIndex = nil
            return
        }
        Self.logger.notice(
            "Re-adopting collapse-removed New VM toolbar item at index \(index, privacy: .public)")
        newVMCollapseRemovalIndex = index
    }

    /// Runs a programmatic toolbar mutation without contaminating the
    /// autosaved configuration.
    private func withAutosaveSuspended(_ toolbar: NSToolbar, _ mutate: () -> Void) {
        let autosaved = toolbar.autosavesConfiguration
        toolbar.autosavesConfiguration = false
        mutate()
        toolbar.autosavesConfiguration = autosaved
    }

    /// Titles the window after the selected VM, so the active VM stays
    /// identifiable when the sidebar is collapsed.
    private func updateWindowTitle() {
        let name = viewModel.selectedInstance?.name
        window?.title = name.map { "Kernova — \($0)" } ?? "Kernova"
    }

    private func updateToolbarItems() {
        guard let toolbar = window?.toolbar else {
            Self.logger.warning("updateToolbarItems: window or toolbar is nil — toolbar state will be stale")
            return
        }

        toolbarManager.updateToolbarItems(in: toolbar)
    }

    // MARK: - NSToolbarDelegate

    // The leading flexible space right-aligns New VM and the toggle against
    // the sidebar's trailing edge.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            Self.toolbarNewVM,
            .toggleSidebar,
            .sidebarTrackingSeparator,
        ] + toolbarManager.defaultItemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.toolbarNewVM,
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .space,
            .flexibleSpace,
        ] + toolbarManager.sharedItemIdentifiers + [
            Self.toolbarClone,
            Self.toolbarShowInFinder,
            Self.toolbarMoveToTrash,
        ]
    }

    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        [.toggleSidebar, .sidebarTrackingSeparator]
    }

    func toolbarWillAddItem(_ notification: Notification) {
        // A palette-added item is born with factory-default labels and enablement,
        // and during will-add it is not yet in `toolbar.items` — refresh one
        // runloop turn later so it reflects VM state.
        Task { @MainActor [weak self] in
            self?.updateToolbarItems()
        }
    }

    // MARK: - Customize Sheet Cleanup

    func windowWillBeginSheet(_ notification: Notification) {
        // The window hosts other sheets too (alerts, the creation wizard), so the
        // recreate in `windowDidEndSheet` must only run for the palette.
        sheetIsCustomizationPalette = window?.toolbar?.customizationPaletteIsRunning ?? false
        // The palette must present the user's canonical layout, so a
        // collapse-removed New VM is restored for the sheet's duration.
        if sheetIsCustomizationPalette, let index = newVMCollapseRemovalIndex,
            let toolbar = window?.toolbar
        {
            restoreNewVMItem(in: toolbar, at: index)
        }
    }

    /// Re-applies toolbar enablement after any sheet, and recreates the app's
    /// custom toolbar items when the closing sheet is the customize palette.
    ///
    /// AppKit bakes the section-specific glass treatment into a bordered item's
    /// view at creation, and a customization drag across the sidebar tracking
    /// separator reuses the existing instance without firing toolbarWillAddItem
    /// or toolbarDidRemoveItem, so a moved item keeps the wrong treatment.
    /// Reinserting at the same index routes through the delegate factory.
    func windowDidEndSheet(_ notification: Notification) {
        // Every sheet, not just the palette: item enablement is applied from the
        // observation with `autovalidates` off, so a refresh that lands while a
        // sheet is up never heals on its own. Re-applying current state is idempotent.
        updateToolbarItems()
        guard sheetIsCustomizationPalette, let toolbar = window?.toolbar else { return }
        sheetIsCustomizationPalette = false

        let customIdentifiers = Set(
            [
                Self.toolbarNewVM,
                Self.toolbarClone,
                Self.toolbarShowInFinder,
                Self.toolbarMoveToTrash,
            ] + toolbarManager.sharedItemIdentifiers)
        let identifiers = toolbar.items.map(\.itemIdentifier)
        for (index, identifier) in identifiers.enumerated() where customIdentifiers.contains(identifier) {
            // The snapshot indices stay valid only while every removal is paired
            // with a successful reinsert; bail out if the toolbar ever disagrees.
            guard index < toolbar.items.count else {
                Self.logger.fault("windowDidEndSheet: toolbar item count drifted during recreate")
                assertionFailure("Toolbar item count drifted during recreate")
                break
            }
            toolbar.removeItem(at: index)
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
        updateToolbarItems()
        // Re-apply the collapse-driven New VM removal that `windowWillBeginSheet`
        // undid for the palette.
        syncNewVMVisibilityToSidebarState()
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
        case Self.toolbarClone:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "Clone",
                symbol: "plus.square.on.square",
                action: #selector(AppDelegate.cloneVM(_:)),
                toolTip: "Clone the selected virtual machine"
            )
        case Self.toolbarShowInFinder:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "Show in Finder",
                symbol: "magnifyingglass",
                action: #selector(AppDelegate.showVMInFinder(_:)),
                toolTip: "Reveal the virtual machine bundle in Finder"
            )
        case Self.toolbarMoveToTrash:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "Move to Trash",
                symbol: "trash",
                action: #selector(AppDelegate.deleteVM(_:)),
                toolTip: "Move the selected virtual machine to the Trash"
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
    /// The palette-only items mirror the menu bar's `validateMenuItem(_:)`
    /// predicates for the same actions, so the two surfaces never disagree.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let instance = viewModel.selectedInstance

        switch item.itemIdentifier {
        case Self.toolbarNewVM:
            return true
        case Self.toolbarShowInFinder:
            // Enabled even while preparing — the bundle already exists on disk.
            return instance != nil
        case Self.toolbarClone:
            guard let instance else { return false }
            return instance.status.canEditSettings && !viewModel.hasPreparing
        case Self.toolbarMoveToTrash:
            return instance?.canDelete ?? false
        default:
            guard let instance, !instance.isPreparing else { return false }

            if toolbarManager.sharedItemIdentifiers.contains(item.itemIdentifier) {
                // Group subitems are enabled/disabled directly in updateToolbarItems()
                return true
            }

            Self.logger.debug(
                "validateToolbarItem: unrecognized identifier '\(item.itemIdentifier.rawValue, privacy: .public)'")
            return true
        }
    }
}

// MARK: - Snap-to-fit split view controller

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

        // `proposedPosition` is a divider coordinate; the outline is inset a few
        // points from the pane's trailing edge, so the snap target must be
        // expressed as a pane width, not an outline width. The view controller's
        // own `view.frame` is in its wrapper's coordinates, so walk up to the
        // split view's direct child for the live divider position.
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
