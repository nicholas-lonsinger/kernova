import Cocoa
import os

/// Shared toolbar logic for VM window controllers.
///
/// Creates and manages the lifecycle,
/// suspend, clipboard, and display toolbar items that appear in both the main
/// window and per-VM display windows.
///
/// Each window controller creates its own `VMToolbarManager` with a ``Configuration``
/// that captures per-controller differences (toolbar item identifiers, preparing checks,
/// display capability gating) and an `instanceProvider` closure that resolves the
/// current `VMInstance`.
@MainActor
final class VMToolbarManager: NSObject {
    struct Configuration {
        /// Toolbar item identifiers (different strings per controller to avoid AppKit conflicts).
        let lifecycleID: NSToolbarItem.Identifier
        let saveStateID: NSToolbarItem.Identifier
        let clipboardID: NSToolbarItem.Identifier?
        let popOutID: NSToolbarItem.Identifier
        let fullscreenID: NSToolbarItem.Identifier
        /// When non-nil, a gear-icon button that toggles the detail pane between the live
        /// display and the (read-only) settings form.
        ///
        /// Only the main window sets this; the
        /// pop-out window has no settings pane.
        let settingsToggleID: NSToolbarItem.Identifier?

        /// When `true`, checks `instance.isPreparing` and disables all items while preparing.
        /// `MainWindowController` sets this to `true`; `VMDisplayWindowController` sets it to `false`.
        let checksPreparing: Bool

        /// When `true`, gates display button enablement on `instance.canUseExternalDisplay`.
        /// `MainWindowController` sets this to `true`; `VMDisplayWindowController` sets it to `false`
        /// (display buttons are always enabled in the pop-out window).
        let gatesDisplayOnCapability: Bool
    }

    /// All shared toolbar item identifiers, for use in `NSToolbarDelegate` methods.
    var sharedItemIdentifiers: [NSToolbarItem.Identifier] {
        var ids = [configuration.lifecycleID, configuration.saveStateID]
        if let clipboardID = configuration.clipboardID {
            ids.append(clipboardID)
        }
        ids.append(configuration.popOutID)
        ids.append(configuration.fullscreenID)
        if let settingsToggleID = configuration.settingsToggleID {
            ids.append(settingsToggleID)
        }
        return ids
    }

    /// The shared items in default-layout order, with fixed spaces between the
    /// glass capsule clusters.
    ///
    /// Adjacent bordered items merge into one shared capsule platter (see
    /// docs/TOOLBAR.md), so the spaces choose the groupings: Suspend +
    /// Clipboard together, the display pair together, the settings toggle on
    /// its own. The lifecycle group needs no space — an `NSToolbarItemGroup`
    /// always gets its own platter.
    var defaultItemIdentifiers: [NSToolbarItem.Identifier] {
        var ids = [configuration.lifecycleID, configuration.saveStateID]
        if let clipboardID = configuration.clipboardID {
            ids.append(clipboardID)
        }
        ids += [.space, configuration.popOutID, configuration.fullscreenID]
        if let settingsToggleID = configuration.settingsToggleID {
            ids += [.space, settingsToggleID]
        }
        return ids
    }

    private let configuration: Configuration
    private let instanceProvider: () -> VMInstance?

    private static let logger = Logger(subsystem: "app.kernova", category: "VMToolbarManager")

    // MARK: - Clipboard transfer-progress state

    /// The VM whose `transferProgress` the clipboard item currently reflects;
    /// weak so it never keeps an instance alive.
    ///
    /// Identity-compared to re-arm the observation only on a real selection swap.
    private weak var clipboardObservedInstance: VMInstance?
    private weak var clipboardProgressToolbar: NSToolbar?
    private var clipboardProgressObservation: ObservationLoop?

    // MARK: - Tooltip Constants

    private static let startToolTip = "Start the virtual machine"
    private static let resumeToolTip = "Resume the virtual machine"
    private static let installToolTip = "Download macOS and start the installation"
    private static let resumeInstallToolTip = "Resume the interrupted download and install macOS"
    private static let pauseToolTip = "Pause the virtual machine"
    private static let stopToolTip = "Stop the virtual machine"
    private static let discardSavedStateToolTip = "Discard the virtual machine's saved state"
    private static let saveStateToolTip = "Suspend the virtual machine"
    private static let popOutToolTip = "Open display in a separate window"
    private static let popInToolTip = "Return display to the main window"
    private static let fullscreenToolTip = "Enter fullscreen display"
    private static let exitFullscreenToolTip = "Exit fullscreen display"
    private static let showSettingsToolTip = "Show settings (read-only while the VM is running)"
    private static let showDisplayToolTip = "Return to the VM display"

    private enum LifecycleSegment: Int {
        case play = 0, pause = 1, stop = 2
    }

    // MARK: - Init

    init(configuration: Configuration, instanceProvider: @escaping () -> VMInstance?) {
        var allIDs = [
            configuration.lifecycleID, configuration.saveStateID,
            configuration.popOutID, configuration.fullscreenID,
        ]
        if let clipboardID = configuration.clipboardID { allIDs.append(clipboardID) }
        if let settingsToggleID = configuration.settingsToggleID { allIDs.append(settingsToggleID) }
        assert(
            Set(allIDs).count == allIDs.count,
            "VMToolbarManager.Configuration identifiers must be distinct")
        self.configuration = configuration
        self.instanceProvider = instanceProvider
        super.init()
    }

    // MARK: - Item Factory

    /// Creates the `NSToolbarItem` for the given identifier, or returns `nil` if it is not
    /// a shared item managed by this manager.
    ///
    /// Called from the controller's
    /// `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`.
    func makeToolbarItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case configuration.lifecycleID:
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: [
                    .systemSymbol("play.fill", accessibilityDescription: "Start"),
                    .systemSymbol("pause.fill", accessibilityDescription: "Pause"),
                    .systemSymbol("stop.fill", accessibilityDescription: "Stop"),
                ],
                selectionMode: .momentary,
                labels: ["Start", "Pause", "Stop"],
                target: self,
                action: #selector(lifecycleAction(_:))
            )
            group.label = "State Controls"
            group.subitems[LifecycleSegment.play.rawValue].toolTip = Self.startToolTip
            group.subitems[LifecycleSegment.pause.rawValue].toolTip = Self.pauseToolTip
            group.subitems[LifecycleSegment.stop.rawValue].toolTip = Self.stopToolTip
            group.autovalidates = false
            return group

        case configuration.saveStateID:
            return makeBorderedItem(
                identifier: identifier,
                label: "Suspend",
                symbol: "moon.zzz.fill",
                action: #selector(AppDelegate.saveVM(_:)),
                toolTip: Self.saveStateToolTip
            )

        case configuration.clipboardID:
            // A view-backed item so the transfer bar is a real subview over the
            // glyph (Safari's downloads-button construction) rather than baked
            // into the item's image; the button reproduces the native platter
            // treatment (see ClipboardToolbarButton).
            let button = ClipboardToolbarButton()
            button.target = nil
            button.action = #selector(AppDelegate.showClipboard(_:))
            button.toolTip = "Open the clipboard sharing window"
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Clipboard"
            item.paletteLabel = "Clipboard"
            item.view = button
            item.autovalidates = false
            return item

        case configuration.popOutID:
            return makeBorderedItem(
                identifier: identifier,
                label: "Pop Out",
                symbol: "pip.exit",
                action: #selector(AppDelegate.togglePopOut(_:)),
                toolTip: Self.popOutToolTip
            )

        case configuration.fullscreenID:
            return makeBorderedItem(
                identifier: identifier,
                label: "Fullscreen",
                symbol: "arrow.up.left.and.arrow.down.right",
                action: #selector(AppDelegate.toggleFullscreen(_:)),
                toolTip: Self.fullscreenToolTip
            )

        case configuration.settingsToggleID:
            let item = makeBorderedItem(
                identifier: identifier,
                label: "Show Settings",
                symbol: "gearshape",
                action: #selector(AppDelegate.toggleSettingsPane(_:)),
                toolTip: Self.showSettingsToolTip
            )
            // The runtime label flips between Show/Hide Settings; the customize
            // palette needs a stable name.
            item.paletteLabel = "Settings"
            return item

        default:
            return nil
        }
    }

    // MARK: - Toolbar State Updates

    /// Updates all shared toolbar items in the given toolbar to reflect current VM state.
    func updateToolbarItems(in toolbar: NSToolbar) {
        let instance = resolveActiveInstance()
        updateLifecycleGroup(in: toolbar, instance: instance)
        updateSaveStateItem(in: toolbar, instance: instance)
        updateClipboardItem(in: toolbar, instance: instance)
        updatePopOutItem(in: toolbar, instance: instance)
        updateFullscreenItem(in: toolbar, instance: instance)
        updateSettingsToggleItem(in: toolbar, instance: instance)
    }

    /// Whether the display items should be enabled for the given instance,
    /// honoring the per-controller capability gate.
    private func displayItemsEnabled(for instance: VMInstance?) -> Bool {
        guard let instance else { return false }
        return configuration.gatesDisplayOnCapability ? instance.canUseExternalDisplay : true
    }

    private func updateLifecycleGroup(in toolbar: NSToolbar, instance: VMInstance?) {
        // Absence is legitimate — the user may have removed the item via toolbar
        // customization (matching the silent skips in updateClipboardItem and
        // updateSettingsToggleItem).
        guard let item = toolbar.items.first(where: { $0.itemIdentifier == configuration.lifecycleID })
        else { return }
        guard let group = item as? NSToolbarItemGroup, group.subitems.count == 3 else {
            Self.logger.warning("updateLifecycleGroup: lifecycle group malformed — wrong type or subitem count")
            return
        }

        guard let instance else {
            group.subitems.forEach { $0.isEnabled = false }
            return
        }

        let canResume = instance.status.canResume
        // `startAction` triggers on installContext (not status) so .error retries —
        // which happen when a previous install attempt failed — also get the
        // install-flavored labels and reflect what Start will actually do.
        let startAction = instance.startAction
        let playLabel: String
        let playToolTip: String
        switch startAction {
        case .install:
            playLabel = startAction.label
            playToolTip = Self.installToolTip
        case .resumeInstall:
            playLabel = startAction.label
            playToolTip = Self.resumeInstallToolTip
        case .start where canResume:
            playLabel = "Resume"
            playToolTip = Self.resumeToolTip
        case .start:
            playLabel = startAction.label
            playToolTip = Self.startToolTip
        }

        let play = group.subitems[LifecycleSegment.play.rawValue]
        if play.label != playLabel {
            play.label = playLabel
            play.image = .systemSymbol("play.fill", accessibilityDescription: playLabel)
            play.toolTip = playToolTip
        }

        play.isEnabled = instance.status.canStart || canResume
        group.subitems[LifecycleSegment.pause.rawValue].isEnabled = instance.status.canPause

        // canStop excludes cold-paused (no graceful stop possible); isColdPaused enables
        // the "discard saved state" path, and the label names that consequence
        // (matching the menu bar and sidebar context menu).
        let stop = group.subitems[LifecycleSegment.stop.rawValue]
        let stopLabel = instance.stopActionToolbarLabel
        if stop.label != stopLabel {
            stop.label = stopLabel
            stop.image = .systemSymbol("stop.fill", accessibilityDescription: stopLabel)
            stop.toolTip = instance.isColdPaused ? Self.discardSavedStateToolTip : Self.stopToolTip
        }
        stop.isEnabled = instance.canStop || instance.isColdPaused
    }

    private func updateSaveStateItem(in toolbar: NSToolbar, instance: VMInstance?) {
        // Absence is legitimate under user customization — skip silently.
        guard let item = toolbar.items.first(where: { $0.itemIdentifier == configuration.saveStateID })
        else { return }

        item.isEnabled = instance?.canSave ?? false
    }

    private func updateClipboardItem(in toolbar: NSToolbar, instance: VMInstance?) {
        // Absence is legitimate under user customization — skip silently (matches
        // the other update* methods).
        guard let clipboardID = configuration.clipboardID,
            let item = toolbar.items.first(where: { $0.itemIdentifier == clipboardID })
        else { return }

        item.isEnabled = instance?.canShowClipboard ?? false

        // Re-arm the transfer-progress observation onto the current VM so the
        // button's bar tracks in-flight transfers — without re-running the
        // whole toolbar update on every chunk.
        if instance !== clipboardObservedInstance {
            clipboardObservedInstance = instance
            clipboardProgressToolbar = toolbar
            clipboardProgressObservation?.cancel()
            clipboardProgressObservation =
                instance == nil
                ? nil
                : observeRecurring(
                    track: { [weak self] in
                        _ = self?.clipboardObservedInstance?.clipboardService?.transferProgress
                    },
                    apply: { [weak self] in self?.refreshClipboardTransferBar() })
        }
        refreshClipboardTransferBar()
    }

    /// Pushes the current transfer fraction (or idle `nil`) into the clipboard
    /// button's bar.
    private func refreshClipboardTransferBar() {
        guard let clipboardID = configuration.clipboardID,
            let toolbar = clipboardProgressToolbar,
            let button = toolbar.items.first(where: { $0.itemIdentifier == clipboardID })?.view
                as? ClipboardToolbarButton
        else { return }

        button.transferFraction =
            clipboardObservedInstance?.clipboardService?.transferProgress?.fractionComplete
    }

    private func updateSettingsToggleItem(in toolbar: NSToolbar, instance: VMInstance?) {
        guard let settingsToggleID = configuration.settingsToggleID,
            let item = toolbar.items.first(where: { $0.itemIdentifier == settingsToggleID })
        else {
            return
        }

        // Only meaningful when there's an actual display the user could be looking at.
        // In other states (stopped, starting, installing) the settings form is already
        // — or is about to become — the only view, so there's nothing to toggle to.
        item.isEnabled = instance?.status.hasActiveDisplay ?? false

        let inSettingsMode = instance?.detailPaneMode == .settings
        let desiredLabel = inSettingsMode ? "Hide Settings" : "Show Settings"

        // Guard reassignment behind the label check so no-op updates don't trigger
        // an AppKit redraw (matches the pattern used by the lifecycle and display groups).
        if item.label != desiredLabel {
            item.label = desiredLabel
            item.image = .systemSymbol(
                inSettingsMode ? "gearshape.fill" : "gearshape",
                accessibilityDescription: desiredLabel
            )
            item.toolTip = inSettingsMode ? Self.showDisplayToolTip : Self.showSettingsToolTip
        }
    }

    private func updatePopOutItem(in toolbar: NSToolbar, instance: VMInstance?) {
        // Absence is legitimate under user customization — skip silently.
        guard let item = toolbar.items.first(where: { $0.itemIdentifier == configuration.popOutID })
        else { return }

        item.isEnabled = displayItemsEnabled(for: instance)

        guard let instance else { return }
        let label = instance.isDisplayDetached ? "Pop In" : "Pop Out"
        if item.label != label {
            item.label = label
            item.image = .systemSymbol(
                instance.isDisplayDetached ? "pip.enter" : "pip.exit",
                accessibilityDescription: label
            )
            item.toolTip = instance.isDisplayDetached ? Self.popInToolTip : Self.popOutToolTip
        }
    }

    private func updateFullscreenItem(in toolbar: NSToolbar, instance: VMInstance?) {
        // Absence is legitimate under user customization — skip silently.
        guard
            let item = toolbar.items.first(where: { $0.itemIdentifier == configuration.fullscreenID })
        else { return }

        item.isEnabled = displayItemsEnabled(for: instance)

        guard let instance else { return }
        let label = instance.isInFullscreen ? "Exit Fullscreen" : "Fullscreen"
        if item.label != label {
            item.label = label
            item.image = .systemSymbol(
                instance.isInFullscreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                accessibilityDescription: label
            )
            item.toolTip =
                instance.isInFullscreen
                ? Self.exitFullscreenToolTip : Self.fullscreenToolTip
        }
    }

    // MARK: - Actions

    @objc private func lifecycleAction(_ group: NSToolbarItemGroup) {
        guard let segment = LifecycleSegment(rawValue: group.selectedIndex) else {
            Self.logger.warning("lifecycleAction: unexpected selectedIndex \(group.selectedIndex, privacy: .public)")
            return
        }
        switch segment {
        case .play:
            if instanceProvider()?.status.canResume ?? false {
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

    // MARK: - Helpers

    /// Resolves the current VM instance, returning `nil` if no instance is available
    /// or (when configured) the instance is preparing.
    private func resolveActiveInstance() -> VMInstance? {
        guard let instance = instanceProvider() else {
            Self.logger.debug("resolveActiveInstance: no instance available")
            return nil
        }
        if configuration.checksPreparing && instance.isPreparing { return nil }
        return instance
    }

    /// Creates a bordered image-backed item — the standard single-button shape,
    /// which merges into a shared glass capsule with adjacent bordered items.
    ///
    /// The factory label doubles as the stable palette label; state-dependent
    /// relabeling (Pop Out ⇆ Pop In) happens in the update methods.
    private func makeBorderedItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector,
        toolTip: String
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.image = .systemSymbol(symbol, accessibilityDescription: label)
        item.action = action
        item.toolTip = toolTip
        item.isBordered = true
        // RATIONALE: the update methods own enabled state; with autovalidation
        // on, AppKit would force isEnabled=true and fight the manual updates,
        // producing a visible flicker when switching between stopped VMs.
        item.autovalidates = false
        return item
    }
}
