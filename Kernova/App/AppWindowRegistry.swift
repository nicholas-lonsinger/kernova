import Cocoa
import KernovaLogging

/// The one owner of which user-facing windows exist, and whether any of them is
/// on screen.
///
/// Every window a person can see belongs here — the library, Settings, the
/// config check, the per-VM clipboard windows, and the display windows
/// ``VMDisplayPlacementController`` places — so the presence question has a
/// single answer rather than one per owner.
@MainActor
final class AppWindowRegistry {
    private let viewModel: VMLibraryViewModel
    /// The one owner of where each VM's display lives, held here so the display
    /// windows count toward presence alongside the rest.
    let displayPlacement: VMDisplayPlacementController
    /// The residency decisions this registry needs but cannot make — and, by
    /// the same token, the ones the display windows it holds need, so setting
    /// it here is what settles the question for every window in the registry.
    weak var residency: (any WindowResidencyHosting)? {
        didSet { displayPlacement.residency = residency }
    }

    private let autosaveScope: WindowAutosaveScope
    /// Brings Kernova forward, for a window the user asked for.
    private let activateApp: @MainActor () -> Void
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var clipboardWindows: [UUID: ClipboardWindowController] = [:]

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "AppWindowRegistry")

    init(
        viewModel: VMLibraryViewModel,
        displayPlacement: VMDisplayPlacementController,
        autosaveScope: WindowAutosaveScope,
        activateApp: @escaping @MainActor () -> Void = { NSApp.activate() }
    ) {
        self.viewModel = viewModel
        self.displayPlacement = displayPlacement
        self.autosaveScope = autosaveScope
        self.activateApp = activateApp
        displayPlacement.host = self
    }

    // MARK: - Library

    var libraryWindow: NSWindow? { mainWindowController?.window }

    /// The library's detail pane, which hosts a VM's inline display.
    var libraryDetailContainer: DetailContainerViewController? {
        mainWindowController?.detailContainer
    }

    func showLibrary(bringToFront: Bool) {
        residency?.prepareToPresentWindow()
        if let existingWindow = mainWindowController?.window {
            if bringToFront {
                #log(Self.logger, .debug, "showLibrary: focusing existing window")
                existingWindow.makeKeyAndOrderFront(nil)
            } else {
                #log(Self.logger, .debug, "showLibrary: showing existing window in background")
                existingWindow.orderBack(nil)
            }
        } else {
            #log(Self.logger, .notice, "showLibrary: recreating main window controller")
            let windowController = MainWindowController(
                viewModel: viewModel, autosaveScope: autosaveScope)
            if bringToFront {
                windowController.showWindow(nil)
            } else {
                windowController.showWindowInBackground()
            }
            mainWindowController = windowController
        }
    }

    func revealLibrarySidebar() {
        mainWindowController?.revealSidebar()
    }

    /// Brings the library window forward — opening it if there is none — with
    /// the keyboard in its sidebar's search field.
    func focusLibrarySearch() {
        showLibrary(bringToFront: true)
        mainWindowController?.focusSearch()
    }

    /// The library window's sidebar while that window is on screen.
    var librarySidebar: SidebarViewController? {
        guard let mainWindowController, mainWindowController.window?.isVisible == true else { return nil }
        return mainWindowController.sidebarViewController
    }

    // MARK: - Settings

    var settingsWindow: NSWindow? { settingsWindowController?.window }

    /// Shows the Settings window on `destination`, or on the pane it was last
    /// left on when `nil`.
    func showSettings(at destination: SettingsDestination? = nil) {
        residency?.prepareToPresentWindow()
        let controller =
            settingsWindowController
            ?? SettingsWindowController(viewModel: viewModel, autosaveScope: autosaveScope)
        settingsWindowController = controller
        if let destination { controller.tabs.show(destination) }
        activateApp()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Config check

    private var configCheckWindowController: ConfigCheckWindowController?

    var configCheckWindow: NSWindow? { configCheckWindowController?.window }

    /// Shows the Check Config Files window, checking every config file again:
    /// in front and key, with Kernova brought forward, for the user's
    /// `request`; in front of Kernova's other windows alone for an automatic
    /// one.
    func showConfigCheck(_ request: VMLibraryViewModel.ConfigCheckRequest) {
        residency?.prepareToPresentWindow()
        let controller =
            configCheckWindowController
            ?? ConfigCheckWindowController(viewModel: viewModel, autosaveScope: autosaveScope)
        configCheckWindowController = controller
        switch request {
        case .user:
            activateApp()
            controller.showAndCheck(makingKey: true)
        case .automatic:
            controller.showAndCheck(makingKey: false)
        }
    }

    // MARK: - Clipboard

    /// Shows or focuses the clipboard window for `instance`, when the VM's state
    /// admits one.
    func showClipboard(for instance: VMInstance) {
        guard viewModel.capabilities.accepts(.showClipboard, on: instance) else { return }
        residency?.prepareToPresentWindow()

        let vmID = instance.instanceID
        if let existing = clipboardWindows[vmID] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = ClipboardWindowController(
            instance: instance, viewModel: viewModel, autosaveScope: autosaveScope)
        controller.onWillClose = { [weak self] in
            self?.clipboardWindows.removeValue(forKey: vmID)
        }
        clipboardWindows[vmID] = controller
        controller.showWindow(nil)
    }

    func clipboardWindow(for vmID: UUID) -> NSWindow? { clipboardWindows[vmID]?.window }

    // MARK: - Presence

    /// The VM whose display or clipboard window is `window`, if any.
    func instance(forKeyWindow window: NSWindow) -> VMInstance? {
        if let instance = displayPlacement.instance(forKeyWindow: window) { return instance }
        return clipboardWindows.values.first(where: { $0.window === window })?.instance
    }

    /// Whether any window this registry tracks is on screen, optionally counting
    /// a miniaturized one as present.
    func hasTrackedUserWindow(countingMiniaturized: Bool) -> Bool {
        func onScreen(_ window: NSWindow?) -> Bool {
            guard let window else { return false }
            return window.isVisible || (countingMiniaturized && window.isMiniaturized)
        }
        if onScreen(libraryWindow) { return true }
        if displayPlacement.hasWindow(where: { onScreen($0) }) { return true }
        if clipboardWindows.values.contains(where: { onScreen($0.window) }) { return true }
        if onScreen(settingsWindow) { return true }
        if onScreen(configCheckWindow) { return true }
        return false
    }

    /// Whether any user-facing Kernova window is currently on screen, optionally
    /// counting a miniaturized one as present.
    ///
    /// Does NOT special-case `NSApp.isHidden`, which turns every window's
    /// `isVisible` false without closing one: this answers what is on screen,
    /// and hiding is a term of the residency decision instead — see
    /// ``AppResidencyController/residencyOutcome(hasVisibleUserWindow:isHidden:keepInMenuBar:hasUninterruptibleWork:)``.
    func hasUserWindow(countingMiniaturized: Bool) -> Bool {
        if hasTrackedUserWindow(countingMiniaturized: countingMiniaturized) { return true }
        // Untracked AppKit-owned panels are genuine on-screen windows: count them
        // so a reconcile can't strip the Dock icon while one is the last visible.
        // `isUntrackedUserPanel` itself always admits a miniaturized panel, so
        // the parameter is honored here by additionally requiring `isVisible`
        // when miniaturized windows don't count.
        func isOnScreenUntrackedPanel(_ window: NSWindow) -> Bool {
            Self.isUntrackedUserPanel(window) && (countingMiniaturized || window.isVisible)
        }
        return NSApp.windows.contains(where: isOnScreenUntrackedPanel)
    }

    /// Whether `window` is an untracked, AppKit-owned top-level panel whose
    /// presence must keep the Dock icon.
    ///
    /// The standard About panel is the motivating example. The visible +
    /// normal-level + titled filter excludes chrome: the status item's backing
    /// `NSStatusBarWindow` is borderless and sits above `.normal`, so an
    /// unfiltered `NSApp.windows` scan would pin the agent to `.regular` forever.
    static func isUntrackedUserPanel(_ window: NSWindow) -> Bool {
        (window.isVisible || window.isMiniaturized)
            && window.level == .normal
            && window.styleMask.contains(.titled)
    }

    // MARK: - Dismissal

    /// Closes every user-facing window, returning the agent to its headless
    /// `.accessory` state.
    ///
    /// Display windows close as app-initiated dismissals so their handler returns
    /// `displayMode` to `.inline` (not the user-close `.hidden`) and leaves
    /// `displayPreference` intact. Collections are snapshotted because closing
    /// mutates them.
    func closeAll() {
        displayPlacement.closeAllForAppDismissal()
        for controller in Array(clipboardWindows.values) { controller.window?.close() }
        settingsWindow?.close()
        configCheckWindow?.close()
        mainWindowController?.window?.close()
    }
}

// MARK: - VMDisplayPlacementHosting

extension AppWindowRegistry: VMDisplayPlacementHosting {
    var libraryScreen: NSScreen? { libraryWindow?.screen }
}
