import Cocoa
import os

/// Shared toolbar logic for VM window controllers.
///
/// Creates and manages the lifecycle,
/// suspend, and display toolbar item groups that appear in both the main window
/// and per-VM display windows.
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
        let displayID: NSToolbarItem.Identifier
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
        ids.append(configuration.displayID)
        if let settingsToggleID = configuration.settingsToggleID {
            ids.append(settingsToggleID)
        }
        return ids
    }

    private let configuration: Configuration
    private let instanceProvider: () -> VMInstance?

    private static let logger = Logger(subsystem: "app.kernova", category: "VMToolbarManager")

    // MARK: - Clipboard transfer-progress state

    private static let clipboardSymbolName = "doc.on.clipboard"
    /// The plain template clipboard glyph shown when no transfer is in flight.
    private lazy var clipboardBaseImage = NSImage.systemSymbol(
        Self.clipboardSymbolName, accessibilityDescription: "Clipboard")
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

    private enum DisplaySegment: Int {
        case popOutOrIn = 0, fullscreen = 1
    }

    // MARK: - Init

    init(configuration: Configuration, instanceProvider: @escaping () -> VMInstance?) {
        var allIDs = [configuration.lifecycleID, configuration.saveStateID, configuration.displayID]
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
            return makeSingleItemGroup(
                identifier: identifier,
                label: "Suspend",
                symbol: "moon.zzz.fill",
                action: #selector(AppDelegate.saveVM(_:)),
                toolTip: Self.saveStateToolTip
            )

        case configuration.clipboardID:
            // A native single-item group (identical machinery to Suspend) so it
            // gets the standard toolbar pill, hover highlight, and sizing. The
            // Safari-style transfer bar is composited *into* this item's image by
            // `updateClipboardItem` rather than overlaid as a custom view, which
            // would forfeit that native styling.
            return makeSingleItemGroup(
                identifier: identifier,
                label: "Clipboard",
                symbol: Self.clipboardSymbolName,
                action: #selector(AppDelegate.showClipboard(_:)),
                toolTip: "Open the clipboard sharing window"
            )

        case configuration.displayID:
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: [
                    .systemSymbol("pip.exit", accessibilityDescription: "Pop Out"),
                    .systemSymbol("arrow.up.left.and.arrow.down.right", accessibilityDescription: "Fullscreen"),
                ],
                selectionMode: .momentary,
                labels: ["Pop Out", "Fullscreen"],
                target: self,
                action: #selector(displayAction(_:))
            )
            group.label = "Display"
            group.subitems[DisplaySegment.popOutOrIn.rawValue].toolTip = Self.popOutToolTip
            group.subitems[DisplaySegment.fullscreen.rawValue].toolTip = Self.fullscreenToolTip
            group.autovalidates = false
            return group

        case configuration.settingsToggleID:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Show Settings"
            // The runtime label flips between Show/Hide Settings; the customize
            // palette needs a stable name.
            item.paletteLabel = "Settings"
            item.image = .systemSymbol("gearshape", accessibilityDescription: "Show Settings")
            item.action = #selector(AppDelegate.toggleSettingsPane(_:))
            item.toolTip = Self.showSettingsToolTip
            item.isBordered = true
            // RATIONALE: `updateSettingsToggleItem` owns the enabled state; with
            // autovalidation on, AppKit would force isEnabled=true (validateToolbarItem
            // returns true for any shared identifier) and fight our manual updates,
            // producing a visible flicker when switching between stopped VMs.
            item.autovalidates = false
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
        updateDisplayGroup(in: toolbar, instance: instance)
        updateSettingsToggleItem(in: toolbar, instance: instance)
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
        guard let group = item as? NSToolbarItemGroup, let subitem = group.subitems.first else {
            Self.logger.warning("updateSaveStateItem: save state group malformed — wrong type or empty")
            return
        }

        guard let instance else {
            subitem.isEnabled = false
            return
        }

        subitem.isEnabled = instance.canSave
    }

    private func updateClipboardItem(in toolbar: NSToolbar, instance: VMInstance?) {
        // Absence is legitimate under user customization — skip silently (matches
        // the other update* methods).
        guard let clipboardID = configuration.clipboardID,
            let group = toolbar.items.first(where: { $0.itemIdentifier == clipboardID })
                as? NSToolbarItemGroup,
            let subitem = group.subitems.first
        else { return }

        subitem.isEnabled = instance?.canShowClipboard ?? false

        // Re-arm the transfer-progress observation onto the current VM so the
        // item's image picks up the composited Safari-style bar — without
        // re-running the whole toolbar update on every chunk.
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
                    apply: { [weak self] in self?.refreshClipboardProgressImage() })
        }
        refreshClipboardProgressImage()
    }

    /// Swaps the clipboard item's icon between the plain template symbol (idle)
    /// and a composited glyph + Safari-style transfer bar (in flight).
    ///
    /// Compositing into the native group item's image keeps the standard toolbar
    /// pill, hover highlight, and sizing — which a custom-view item forfeits.
    private func refreshClipboardProgressImage() {
        guard let clipboardID = configuration.clipboardID,
            let toolbar = clipboardProgressToolbar,
            let group = toolbar.items.first(where: { $0.itemIdentifier == clipboardID })
                as? NSToolbarItemGroup,
            let subitem = group.subitems.first
        else { return }

        if let progress = clipboardObservedInstance?.clipboardService?.transferProgress {
            subitem.image = clipboardProgressImage(fraction: progress.fractionComplete)
        } else if subitem.image !== clipboardBaseImage {
            // Idle: restore the plain glyph, but only when it isn't already shown —
            // this runs on every VM-state toolbar tick, and re-assigning an
            // unchanged image needlessly redraws the item (matches the label/image
            // equality guards used by the other update* methods).
            subitem.image = clipboardBaseImage
        }
    }

    /// Renders the clipboard glyph shrunk into the top of its box with a thin
    /// rounded accent bar (filled to `fraction`) beneath it, at the same pixel
    /// size as the plain symbol so the toolbar item never resizes.
    ///
    /// Drawn via a `drawingHandler` so the dynamic colors resolve in the current
    /// appearance.
    private func clipboardProgressImage(fraction: Double) -> NSImage {
        let base = clipboardBaseImage
        let size = base.size
        let clamped = CGFloat(min(max(fraction, 0), 1))
        let image = NSImage(size: size, flipped: false) { rect in
            let barHeight: CGFloat = 2.5
            let gap: CGFloat = 1.5
            let scale = max(0, (rect.height - barHeight - gap)) / rect.height
            let glyphSize = NSSize(width: rect.width * scale, height: rect.height * scale)
            // Top-aligned (AppKit y-up: maxY is the top), horizontally centered.
            let glyphRect = NSRect(
                x: rect.midX - glyphSize.width / 2,
                y: rect.maxY - glyphSize.height,
                width: glyphSize.width,
                height: glyphSize.height)
            base.draw(in: glyphRect)
            NSColor.labelColor.set()
            glyphRect.fill(using: .sourceAtop)  // tint the template glyph

            let radius = barHeight / 2
            let track = NSRect(x: 0, y: 0, width: rect.width, height: barHeight)
            NSColor.tertiaryLabelColor.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
            let fill = NSRect(x: 0, y: 0, width: rect.width * clamped, height: barHeight)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.isTemplate = false  // keep the baked accent color (not tinted by the item)
        return image
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

    private func updateDisplayGroup(in toolbar: NSToolbar, instance: VMInstance?) {
        // Absence is legitimate under user customization — skip silently.
        guard let item = toolbar.items.first(where: { $0.itemIdentifier == configuration.displayID })
        else { return }
        guard let group = item as? NSToolbarItemGroup, group.subitems.count == 2 else {
            Self.logger.warning("updateDisplayGroup: display group malformed — wrong type or subitem count")
            return
        }

        let popItem = group.subitems[DisplaySegment.popOutOrIn.rawValue]
        let fullscreenItem = group.subitems[DisplaySegment.fullscreen.rawValue]

        guard let instance else {
            popItem.isEnabled = false
            fullscreenItem.isEnabled = false
            return
        }

        if configuration.gatesDisplayOnCapability {
            let canUse = instance.canUseExternalDisplay
            popItem.isEnabled = canUse
            fullscreenItem.isEnabled = canUse
        } else {
            popItem.isEnabled = true
            fullscreenItem.isEnabled = true
        }

        let popLabel = instance.isInSeparateWindow ? "Pop In" : "Pop Out"
        if popItem.label != popLabel {
            popItem.label = popLabel
            popItem.image = .systemSymbol(
                instance.isInSeparateWindow ? "pip.enter" : "pip.exit",
                accessibilityDescription: popLabel
            )
            popItem.toolTip = instance.isInSeparateWindow ? Self.popInToolTip : Self.popOutToolTip
        }

        let fsLabel = instance.isInFullscreen ? "Exit Fullscreen" : "Fullscreen"
        if fullscreenItem.label != fsLabel {
            fullscreenItem.label = fsLabel
            fullscreenItem.image = .systemSymbol(
                instance.isInFullscreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                accessibilityDescription: fsLabel
            )
            fullscreenItem.toolTip =
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

    @objc private func displayAction(_ group: NSToolbarItemGroup) {
        guard let segment = DisplaySegment(rawValue: group.selectedIndex) else {
            Self.logger.warning("displayAction: unexpected selectedIndex \(group.selectedIndex, privacy: .public)")
            return
        }
        switch segment {
        case .popOutOrIn:
            NSApp.sendAction(#selector(AppDelegate.togglePopOut(_:)), to: nil, from: nil)
        case .fullscreen:
            NSApp.sendAction(#selector(AppDelegate.toggleFullscreen(_:)), to: nil, from: nil)
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

    private func makeSingleItemGroup(
        identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector,
        toolTip: String? = nil
    ) -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(
            itemIdentifier: identifier,
            images: [.systemSymbol(symbol, accessibilityDescription: label)],
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
