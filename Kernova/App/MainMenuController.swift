import Cocoa

/// The application-level seam a ``MainMenuController`` needs but cannot own:
/// which VM a command acts on, and the object its explicitly-targeted items fire
/// at.
@MainActor
protocol MainMenuHosting: AnyObject {
    /// The VM a menu command acts on: the one the sending item names, else the
    /// key window's VM, else the sidebar selection. A `nil` sender asks for the
    /// active instance.
    func menuCommandTarget(of sender: Any?) -> VMInstance?
}

/// The one owner of the menu bar: its construction, the rebuilds an opening menu
/// asks for, and the validation that decides every VM command's title and
/// enablement.
///
/// The `@objc` actions the items name stay on `AppDelegate` — every call site
/// dispatches them nil-target down the responder chain, which this controller is
/// not part of. It reaches the app through ``MainMenuHosting``.
@MainActor
final class MainMenuController: NSObject, NSMenuDelegate {
    private let viewModel: VMLibraryViewModel
    /// App-wide preferences, read for the clone alternate's title.
    private let preferences: AppPreferences
    /// Whether a ⌘Q in this process downgrades to a GUI close rather than
    /// terminating — the same predicate
    /// ``AppTerminationController/shouldTerminateOnQuit`` gates on, so the menu
    /// can never name a command the gate would not honor.
    private let hasSoftQuit: Bool
    /// Whether this build carries the guest-agent installer disk image the
    /// guest-agent item mounts.
    private let hasBundledGuestAgentDisk: Bool
    weak var host: (any MainMenuHosting)?

    /// The application menu, retained so its quit section can be rebuilt when it opens.
    private var appMenu: NSMenu?
    /// The quit-section items currently installed in `appMenu`, tracked so a
    /// rebuild removes exactly what it added.
    private var appMenuQuitItemViews: [NSMenuItem] = []
    /// The model `appMenuQuitItemViews` was last built from, so a rebuild that
    /// would produce identical items is skipped.
    private var appMenuQuitModel: [AppMenuQuitItem] = []

    /// The Virtual Machine menu, retained so its opening can refresh the revert
    /// submenu that decides one of its items' enablement.
    private var virtualMachineMenu: NSMenu?
    /// That menu's "Revert to Snapshot" submenu, retained so it can be rebuilt
    /// from the selected VM's manifest when it opens.
    private var revertSnapshotMenu: NSMenu?
    /// What that submenu currently lists, so an open that would produce
    /// identical items skips the rebuild — `menuNeedsUpdate(_:)` also fires
    /// while AppKit matches key equivalents.
    private var revertSnapshotMenuModel: RevertSnapshotMenuModel?

    /// The Window menu, retained so its opening can set the clipboard item's
    /// enablement and so the presence check reads this controller's own menu.
    private var windowsMenu: NSMenu?
    /// The Services menu AppKit fills, retained for the `NSApp` handoff.
    private var servicesMenu: NSMenu?
    /// The Help menu, retained for the `NSApp` handoff.
    private var helpMenu: NSMenu?
    private var clipboardMenuItem: NSMenuItem?

    /// Value snapshot of the revert submenu's rendered contents.
    private struct RevertSnapshotMenuModel: Equatable {
        let instanceID: UUID?
        let snapshots: [VMSnapshot]
        let isEnabled: Bool
    }

    init(
        viewModel: VMLibraryViewModel,
        preferences: AppPreferences,
        hasSoftQuit: Bool,
        hasBundledGuestAgentDisk: Bool = KernovaMacOSAgentInfo.installerDiskImageURL != nil
    ) {
        self.viewModel = viewModel
        self.preferences = preferences
        self.hasSoftQuit = hasSoftQuit
        self.hasBundledGuestAgentDisk = hasBundledGuestAgentDisk
    }

    // MARK: - Quit Section

    /// One item in the app menu's quit section, as decided by `appMenuQuitItems`.
    struct AppMenuQuitItem: Equatable {
        /// What invoking the item does.
        enum Action: Equatable {
            /// Routes through `NSApplication.terminate(_:)` and thus the
            /// `applicationShouldTerminate` gate.
            case terminateThroughGate
            /// Requests an unconditional full quit, bypassing the
            /// keep-in-menu-bar downgrade.
            case quitCompletely
        }

        let title: String
        /// The key-equivalent character (always `"q"`; ⌘ is always part of the shortcut).
        let keyEquivalent: String
        /// Whether Option joins Command: `false` = ⌘Q, `true` = ⌥⌘Q.
        let usesOptionModifier: Bool
        let action: Action
    }

    /// Decides the app menu's quit-section items, so every state presents an
    /// honest command.
    ///
    /// A process whose ⌘Q would be downgraded to a GUI close gets the honest
    /// split — "Close All Windows" (⌘Q) plus the true "Quit Kernova" (⌥⌘Q);
    /// anywhere ⌘Q really quits, it is the single item that says so.
    nonisolated static func appMenuQuitItems(
        downgradesQuitToGUIClose: Bool
    ) -> [AppMenuQuitItem] {
        if downgradesQuitToGUIClose {
            return [
                AppMenuQuitItem(
                    title: "Close All Windows", keyEquivalent: "q",
                    usesOptionModifier: false, action: .terminateThroughGate),
                AppMenuQuitItem(
                    title: "Quit Kernova", keyEquivalent: "q",
                    usesOptionModifier: true, action: .quitCompletely),
            ]
        }
        return [
            AppMenuQuitItem(
                title: "Quit Kernova", keyEquivalent: "q",
                usesOptionModifier: false, action: .terminateThroughGate)
        ]
    }

    // MARK: - Menu Updates

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === windowsMenu {
            clipboardMenuItem?.isEnabled =
                host?.menuCommandTarget(of: nil).map {
                    viewModel.capabilities.isAvailable(.showClipboard, on: $0)
                } ?? false
        } else if menu === appMenu {
            // Re-derive the quit section so a Settings toggle flip is reflected on
            // the next open.
            rebuildAppMenuQuitItems()
        } else if menu === revertSnapshotMenu {
            rebuildRevertSnapshotMenu(menu)
        } else if menu === virtualMachineMenu, let revertSnapshotMenu {
            rebuildRevertSnapshotMenu(revertSnapshotMenu)
        }
    }

    /// Rebuilds the revert submenu from the selected VM's snapshots.
    ///
    /// The unchanged-model guard is load-bearing for the same reason it is in
    /// ``rebuildAppMenuQuitItems()``: this also runs while AppKit matches key
    /// equivalents, and tearing items down mid-match is what must not happen.
    private func rebuildRevertSnapshotMenu(_ menu: NSMenu) {
        // No host means the app is tearing down, and the submenu goes with it.
        guard let host else { return }
        let instance = host.menuCommandTarget(of: nil)
        let model = RevertSnapshotMenuModel(
            instanceID: instance?.id,
            snapshots: instance?.snapshotManifest.ordered ?? [],
            isEnabled: instance.map {
                viewModel.capabilities.isAvailable(.revertToSnapshot, on: $0)
            } ?? false)
        guard model != revertSnapshotMenuModel else { return }
        revertSnapshotMenuModel = model
        SnapshotRevertMenu.rebuild(
            menu, for: instance, isEnabled: model.isEnabled, target: host,
            action: #selector(AppDelegate.revertToSnapshot(_:)))
    }

    /// Rebuilds the app menu's quit section from `appMenuQuitItems` for the
    /// current mode, removing exactly the items a prior rebuild added.
    ///
    /// The unchanged-model guard is load-bearing, not an optimization: AppKit also
    /// calls `menuNeedsUpdate(_:)` while *matching key equivalents*, so this runs
    /// on every ⌘-keystroke — and tearing the items down mid-match is exactly the
    /// mutation that must not happen.
    private func rebuildAppMenuQuitItems() {
        guard let appMenu else { return }
        // The preference is read live here, not captured, so a Settings flip is
        // reflected on the next open.
        let model = Self.appMenuQuitItems(
            downgradesQuitToGUIClose: hasSoftQuit && viewModel.keepInMenuBarOnQuit)
        guard model != appMenuQuitModel else { return }
        appMenuQuitModel = model

        for item in appMenuQuitItemViews { appMenu.removeItem(item) }
        appMenuQuitItemViews = model.map { model in
            let item: NSMenuItem
            switch model.action {
            case .terminateThroughGate:
                // nil target → the responder chain resolves it to NSApp, funneling
                // through `applicationShouldTerminate`'s gate.
                item = NSMenuItem(
                    title: model.title,
                    action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: model.keyEquivalent)
            case .quitCompletely:
                item = NSMenuItem(
                    title: model.title,
                    action: #selector(AppDelegate.quitCompletely(_:)),
                    keyEquivalent: model.keyEquivalent)
                item.target = host
            }
            item.keyEquivalentModifierMask =
                model.usesOptionModifier ? [.command, .option] : [.command]
            return item
        }
        for item in appMenuQuitItemViews { appMenu.addItem(item) }
    }

    // MARK: - Menu Validation

    /// The capability a menu selector performs, or `nil` for an app-level
    /// command no VM's state gates.
    ///
    /// Selectors are AppKit's vocabulary, so the mapping lives here rather than
    /// in the headless catalog.
    static func capability(for action: Selector?) -> VMCapability? {
        switch action {
        case #selector(AppDelegate.startVM(_:)): .start
        case #selector(AppDelegate.startVMInRecovery(_:)): .startInRecovery
        case #selector(AppDelegate.pauseVM(_:)): .pause
        case #selector(AppDelegate.resumeVM(_:)): .resume
        // Cold-paused VMs have no live VM to stop — `stopVM(_:)` routes them to
        // the discard-saved-state confirmation instead, so the menu bar's one
        // stop item covers both capabilities and is validated against both.
        case #selector(AppDelegate.stopVM(_:)): .stop
        // Cold-paused is excluded: the retitled stop item ("Discard Saved
        // State…") is the one surface for that action, and two enabled items
        // must not alias one action under two names.
        case #selector(AppDelegate.forceStopVM(_:)): .forceStop
        case #selector(AppDelegate.saveVM(_:)): .suspend
        case #selector(AppDelegate.takeSnapshot(_:)): .takeSnapshot
        case #selector(AppDelegate.renameVM(_:)): .rename
        // Same gate for the primary and its ⌥-alternate, in both pairs.
        case #selector(AppDelegate.cloneVM(_:)), #selector(AppDelegate.cloneVMAlternate(_:)): .clone
        case #selector(AppDelegate.deleteVM(_:)), #selector(AppDelegate.deleteImmediatelyVM(_:)):
            .delete
        case #selector(AppDelegate.showVMInFinder(_:)): .showInFinder
        // AppKit bypasses NSMenuItemValidation for windowsMenu items, so
        // menuNeedsUpdate(_:) handles the Clipboard item's visual state. This
        // entry covers its keyboard shortcut, which still routes through
        // validateMenuItem(_:).
        case #selector(AppDelegate.showClipboard(_:)): .showClipboard
        case #selector(AppDelegate.toggleGuestAgentDisk(_:)): .toggleGuestAgentDisk
        case #selector(AppDelegate.togglePopOut(_:)): .togglePopOut
        case #selector(AppDelegate.toggleFullscreen(_:)): .toggleFullscreen
        case #selector(AppDelegate.toggleSettingsPane(_:)): .toggleSettingsPane
        default: nil
        }
    }

    /// Decides `menuItem`'s enablement and, for the commands whose wording
    /// depends on state, retitles it.
    func validate(_ menuItem: NSMenuItem) -> Bool {
        // App-level commands — New, Show Library, Open VMs Folder, Quit
        // Completely — are never gated on the selected VM's state, or a
        // preparing import would disable the GUI's only full-quit affordance.
        guard let capability = Self.capability(for: menuItem.action) else { return true }

        // The two titles that do not depend on a VM, applied before the
        // selection guard so neither strands the last selection's wording: the
        // guest-agent item's title is part of what it reports (see
        // `unavailableTitle`), and the clone alternate's names a preference.
        switch menuItem.action {
        case #selector(AppDelegate.toggleGuestAgentDisk(_:)):
            menuItem.title = GuestAgentDiskMenuItem.unavailableTitle
        case #selector(AppDelegate.cloneVMAlternate(_:)):
            menuItem.title = preferences.cloneAlternateMenuTitle
        default:
            break
        }

        guard let instance = host?.menuCommandTarget(of: menuItem) else { return false }
        let isAvailable = viewModel.capabilities.isAvailable(capability, on: instance)

        switch menuItem.action {
        case #selector(AppDelegate.startVM(_:)):
            // Install-flavored title for pending-install VMs.
            menuItem.title = instance.startAction.label
        case #selector(AppDelegate.stopVM(_:)):
            // The title names what this VM's stop does, which is what its own
            // state admits; enablement is the availability read beside it.
            let discardsSavedState = viewModel.capabilities.isApplicable(
                .discardSavedState, to: instance)
            menuItem.title = VMInstance.stopActionMenuTitle(
                discardingSavedState: discardsSavedState)
            return isAvailable
                || viewModel.capabilities.isAvailable(.discardSavedState, on: instance)
        case #selector(AppDelegate.toggleGuestAgentDisk(_:)):
            // Layered over the capability: a bundled DMG for the VM to hold, and
            // the mount/eject model that decides both title and enablement. The
            // unavailable title set above stands unless both hold.
            guard isAvailable, hasBundledGuestAgentDisk else { return false }
            let model = GuestAgentDiskMenuItem.model(
                status: instance.agentStatus,
                isInstallerMounted: viewModel.isGuestAgentInstallerMounted(on: instance))
            menuItem.title = model.title
            return model.isEnabled
        case #selector(AppDelegate.togglePopOut(_:)):
            // `isDisplayDetached` (not window existence): a hidden (headless)
            // display has no window but still pops back *in*.
            menuItem.title = instance.isDisplayDetached ? "Pop In Display" : "Pop Out Display"
        case #selector(AppDelegate.toggleFullscreen(_:)):
            menuItem.title =
                instance.isInFullscreen ? "Exit Fullscreen Display" : "Fullscreen Display"
        default:
            break
        }
        return isAvailable
    }

    // MARK: - Main Menu

    /// Builds the menu bar and installs it, with the four application-level menus
    /// AppKit resolves by reference.
    func install() {
        let mainMenu = makeMainMenu()
        NSApp.servicesMenu = servicesMenu
        NSApp.windowsMenu = windowsMenu
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = mainMenu
    }

    /// Constructs the whole menu bar, retaining the menus whose opening this
    /// controller answers for. Writes nothing to `NSApp`.
    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About Kernova", action: #selector(AppDelegate.showAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(
            withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        self.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Kernova", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // The quit section is built dynamically per mode; `menuNeedsUpdate`
        // rebuilds it, so build it once now for the first open.
        self.appMenu = appMenu
        appMenu.delegate = self
        rebuildAppMenuQuitItems()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            withTitle: "New Virtual Machine…", action: #selector(AppDelegate.newVM(_:)),
            keyEquivalent: "n")
        fileMenu.addItem(.separator())
        // "Open … Folder" (a Finder window of the contents), not "Show in Finder",
        // which reveals an item selected in its parent — and "VMs Folder", not
        // "Library", which the Window menu already uses for the main window.
        fileMenu.addItem(
            withTitle: "Open VMs Folder", action: #selector(AppDelegate.openVMsFolder(_:)),
            keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        // Nil-target standard `NSWindow` actions resolve against the key window's
        // responder chain, so AppKit retitles and disables these items itself.
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let toggleToolbarItem = viewMenu.addItem(
            withTitle: "Show Toolbar",
            action: #selector(NSWindow.toggleToolbarShown(_:)),
            keyEquivalent: "t"
        )
        toggleToolbarItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(
            withTitle: "Customize Toolbar…",
            action: #selector(NSWindow.runToolbarCustomizationPalette(_:)),
            keyEquivalent: ""
        )
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Virtual Machine menu
        let vmMenuItem = NSMenuItem()
        let vmMenu = NSMenu(title: "Virtual Machine")
        vmMenu.addItem(
            withTitle: "Start", action: #selector(AppDelegate.startVM(_:)), keyEquivalent: "r")
        // The ⌥⌘R shortcut is shared with "Resume" — unambiguous because a VM is
        // never both stopped and paused, and recovery precedes Resume in menu order.
        let recoveryItem = vmMenu.addItem(
            withTitle: "Start in Recovery Mode",
            action: #selector(AppDelegate.startVMInRecovery(_:)), keyEquivalent: "r")
        recoveryItem.keyEquivalentModifierMask = [.command, .option]
        let pauseItem = vmMenu.addItem(
            withTitle: "Pause", action: #selector(AppDelegate.pauseVM(_:)), keyEquivalent: "p")
        pauseItem.keyEquivalentModifierMask = [.command, .option]
        let resumeItem = vmMenu.addItem(
            withTitle: "Resume", action: #selector(AppDelegate.resumeVM(_:)), keyEquivalent: "r")
        resumeItem.keyEquivalentModifierMask = [.command, .option]
        vmMenu.addItem(
            withTitle: "Stop", action: #selector(AppDelegate.stopVM(_:)), keyEquivalent: "")
        vmMenu.addItem(
            withTitle: "Force Stop…", action: #selector(AppDelegate.forceStopVM(_:)),
            keyEquivalent: "")
        vmMenu.addItem(.separator())
        let saveItem = vmMenu.addItem(
            withTitle: "Suspend", action: #selector(AppDelegate.saveVM(_:)), keyEquivalent: "s")
        saveItem.keyEquivalentModifierMask = [.command, .option]
        // "Take Snapshot…" gathers input (the sheet's name and notes), so the
        // ellipsis is HIG-correct here.
        let takeSnapshotItem = vmMenu.addItem(
            withTitle: "Take Snapshot\u{2026}", action: #selector(AppDelegate.takeSnapshot(_:)),
            keyEquivalent: "s")
        takeSnapshotItem.keyEquivalentModifierMask = [.command, .shift]
        let revertItem = NSMenuItem(title: SnapshotRevertMenu.title, action: nil, keyEquivalent: "")
        let revertMenu = NSMenu(title: SnapshotRevertMenu.title)
        // Rebuilt from the selected VM's manifest whenever this submenu or the
        // menu holding it opens — the latter because AppKit decides the parent
        // item's enablement from the submenu's contents, before the submenu
        // itself is ever asked to update.
        revertMenu.delegate = self
        revertItem.submenu = revertMenu
        revertSnapshotMenu = revertMenu
        // Seeded so the parent item is never a live entry onto an empty submenu.
        rebuildRevertSnapshotMenu(revertMenu)
        vmMenu.addItem(revertItem)
        vmMenu.delegate = self
        virtualMachineMenu = vmMenu
        vmMenu.addItem(.separator())
        let popOutItem = vmMenu.addItem(
            withTitle: "Pop Out Display",
            action: #selector(AppDelegate.togglePopOut(_:)),
            keyEquivalent: "o"
        )
        popOutItem.keyEquivalentModifierMask = [.command, .shift]
        let fullscreenItem = vmMenu.addItem(
            withTitle: "Fullscreen Display",
            action: #selector(AppDelegate.toggleFullscreen(_:)),
            keyEquivalent: "f"
        )
        fullscreenItem.keyEquivalentModifierMask = [.command, .shift]
        vmMenu.addItem(.separator())
        // No ellipsis on "Rename": it starts an inline edit on the sidebar row (like
        // Finder's single-item Rename), not a dialog.
        vmMenu.addItem(
            withTitle: "Rename", action: #selector(AppDelegate.renameVM(_:)), keyEquivalent: "")
        vmMenu.addItem(
            withTitle: "Clone", action: #selector(AppDelegate.cloneVM(_:)), keyEquivalent: "d")
        // Clones with the opposite machine-identity behavior to the setting.
        // Always visible, like Start in Recovery Mode: this menu shows advanced
        // actions plainly, reserving ⌥-alternates for irreversible ones.
        // `validate(_:)` re-reads the title on every menu open, so a setting
        // change while the menu exists is picked up. The ⌥⌘D key equivalent is
        // eclipsed by the system's Dock-hiding hotkey; the item fires from the
        // pointer.
        let cloneAlternateItem = vmMenu.addItem(
            withTitle: preferences.cloneAlternateMenuTitle,
            action: #selector(AppDelegate.cloneVMAlternate(_:)),
            keyEquivalent: "d")
        cloneAlternateItem.keyEquivalentModifierMask = [.command, .option]
        vmMenu.addItem(
            withTitle: "Show in Finder", action: #selector(AppDelegate.showVMInFinder(_:)),
            keyEquivalent: "")
        vmMenu.addItem(.separator())
        // "Move to Trash…" gathers input (the delete sheet lets the user pick which
        // external files to remove too), so the ellipsis is HIG-correct here.
        let deleteItem = vmMenu.addItem(
            withTitle: "Move to Trash…", action: #selector(AppDelegate.deleteVM(_:)),
            keyEquivalent: "\u{08}")
        deleteItem.keyEquivalentModifierMask = [.command]
        // ⌥-alternate, Finder's idiom for this pair: it is irreversible, so it stays
        // tucked behind Option rather than one slip from the pointer.
        let deleteImmediatelyItem = vmMenu.addItem(
            withTitle: "Delete Immediately…",
            action: #selector(AppDelegate.deleteImmediatelyVM(_:)), keyEquivalent: "\u{08}")
        deleteImmediatelyItem.keyEquivalentModifierMask = [.command, .option]
        deleteImmediatelyItem.isAlternate = true
        vmMenu.addItem(.separator())
        // Title is a placeholder — `validate(_:)` retitles per agent status and
        // attach state on every menu open.
        vmMenu.addItem(
            NSMenuItem(
                title: GuestAgentDiskMenuItem.unavailableTitle,
                action: #selector(AppDelegate.toggleGuestAgentDisk(_:)),
                keyEquivalent: ""
            ))
        vmMenuItem.submenu = vmMenu
        mainMenu.addItem(vmMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let showLibraryItem = NSMenuItem(
            title: "Show Library",
            action: #selector(AppDelegate.showLibrary(_:)),
            keyEquivalent: "0"
        )
        windowMenu.addItem(showLibraryItem)
        windowMenu.addItem(.separator())
        let clipboardItem = NSMenuItem(
            title: "Clipboard",
            action: #selector(AppDelegate.showClipboard(_:)),
            keyEquivalent: "v"
        )
        clipboardItem.keyEquivalentModifierMask = [.command, .shift]
        clipboardMenuItem = clipboardItem
        windowMenu.addItem(clipboardItem)
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        windowsMenu = windowMenu
        windowMenu.delegate = self
        mainMenu.addItem(windowMenuItem)

        // Help menu
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Kernova Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
        helpMenuItem.submenu = helpMenu
        self.helpMenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        return mainMenu
    }
}
