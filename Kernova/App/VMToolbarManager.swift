import Cocoa
import os

/// Shared toolbar logic for VM window controllers. Creates and manages the lifecycle,
/// save-state, and display toolbar item groups that appear in both the main window
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
        let removableMediaID: NSToolbarItem.Identifier?
        let displayID: NSToolbarItem.Identifier

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
        if let removableMediaID = configuration.removableMediaID {
            ids.append(removableMediaID)
        }
        ids.append(configuration.displayID)
        return ids
    }

    private let configuration: Configuration
    private let instanceProvider: () -> VMInstance?

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMToolbarManager")

    // MARK: - Tooltip Constants

    private static let startToolTip = "Start the virtual machine"
    private static let resumeToolTip = "Resume the virtual machine"
    private static let pauseToolTip = "Pause the virtual machine"
    private static let stopToolTip = "Stop the virtual machine"
    private static let saveStateToolTip = "Save the virtual machine state to disk"
    private static let popOutToolTip = "Open display in a separate window"
    private static let popInToolTip = "Return display to the main window"
    private static let fullscreenToolTip = "Enter fullscreen display"
    private static let exitFullscreenToolTip = "Exit fullscreen display"

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
        if let removableMediaID = configuration.removableMediaID { allIDs.append(removableMediaID) }
        assert(Set(allIDs).count == allIDs.count,
               "VMToolbarManager.Configuration identifiers must be distinct")
        self.configuration = configuration
        self.instanceProvider = instanceProvider
        super.init()
    }

    // MARK: - Item Factory

    /// Creates the `NSToolbarItem` for the given identifier, or returns `nil` if it is not
    /// a shared item managed by this manager. Called from the controller's
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
                label: "Save State",
                symbol: "square.and.arrow.down",
                action: #selector(AppDelegate.saveVM(_:)),
                toolTip: Self.saveStateToolTip
            )

        case configuration.clipboardID:
            return makeSingleItemGroup(
                identifier: identifier,
                label: "Clipboard",
                symbol: "doc.on.clipboard",
                action: #selector(AppDelegate.showClipboard(_:)),
                toolTip: "Open the clipboard sharing window"
            )

        case configuration.removableMediaID:
            return makeSingleItemGroup(
                identifier: identifier,
                label: "Removable Media",
                symbol: "opticaldisc",
                action: #selector(AppDelegate.showRemovableMedia(_:)),
                toolTip: "Attach or eject removable media"
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
        updateRemovableMediaItem(in: toolbar, instance: instance)
        updateDisplayGroup(in: toolbar, instance: instance)
    }

    private func updateLifecycleGroup(in toolbar: NSToolbar, instance: VMInstance?) {
        guard let group = toolbar.items.first(where: { $0.itemIdentifier == configuration.lifecycleID }) as? NSToolbarItemGroup,
              group.subitems.count == 3 else {
            Self.logger.warning("updateLifecycleGroup: lifecycle group missing or has unexpected subitem count")
            return
        }

        guard let instance else {
            group.subitems.forEach { $0.isEnabled = false }
            return
        }

        let canResume = instance.status.canResume
        let playLabel = canResume ? "Resume" : "Start"

        let play = group.subitems[LifecycleSegment.play.rawValue]
        if play.label != playLabel {
            play.label = playLabel
            play.image = .systemSymbol("play.fill", accessibilityDescription: playLabel)
            play.toolTip = canResume ? Self.resumeToolTip : Self.startToolTip
        }

        play.isEnabled = instance.status.canStart || canResume
        group.subitems[LifecycleSegment.pause.rawValue].isEnabled = instance.status.canPause
        // canStop excludes cold-paused (no graceful stop possible); isColdPaused enables the "discard saved state" path
        group.subitems[LifecycleSegment.stop.rawValue].isEnabled = instance.canStop || instance.isColdPaused
    }

    private func updateSaveStateItem(in toolbar: NSToolbar, instance: VMInstance?) {
        guard let group = toolbar.items.first(where: { $0.itemIdentifier == configuration.saveStateID }) as? NSToolbarItemGroup,
              let subitem = group.subitems.first else {
            Self.logger.warning("updateSaveStateItem: save state group missing or empty")
            return
        }

        guard let instance else {
            subitem.isEnabled = false
            return
        }

        subitem.isEnabled = instance.canSave
    }

    private func updateClipboardItem(in toolbar: NSToolbar, instance: VMInstance?) {
        guard let clipboardID = configuration.clipboardID,
              let group = toolbar.items.first(where: { $0.itemIdentifier == clipboardID }) as? NSToolbarItemGroup,
              let subitem = group.subitems.first else { return }

        guard let instance else {
            subitem.isEnabled = false
            return
        }

        subitem.isEnabled = instance.canShowClipboard
    }

    private func updateRemovableMediaItem(in toolbar: NSToolbar, instance: VMInstance?) {
        guard let removableMediaID = configuration.removableMediaID,
              let group = toolbar.items.first(where: { $0.itemIdentifier == removableMediaID }) as? NSToolbarItemGroup,
              let subitem = group.subitems.first else { return }

        subitem.isEnabled = instance?.canAttachUSBDevices ?? false
    }

    private func updateDisplayGroup(in toolbar: NSToolbar, instance: VMInstance?) {
        guard let group = toolbar.items.first(where: { $0.itemIdentifier == configuration.displayID }) as? NSToolbarItemGroup,
              group.subitems.count == 2 else {
            Self.logger.warning("updateDisplayGroup: display group missing or has unexpected subitem count")
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
            fullscreenItem.toolTip = instance.isInFullscreen
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
