import Cocoa
import os

/// The one owner of which user-facing windows exist, and whether any of them is
/// on screen.
///
/// Every window a person can see belongs here — the library, Settings, the
/// per-VM clipboard windows, and the display windows
/// ``VMDisplayPlacementController`` places — so the presence question has a
/// single answer rather than one per owner.
@MainActor
final class AppWindowRegistry {
    private let viewModel: VMLibraryViewModel
    /// The one owner of where each VM's display lives, held here so the display
    /// windows count toward presence alongside the rest.
    let displayPlacement: VMDisplayPlacementController
    /// The residency decisions this registry needs but cannot make.
    weak var residency: (any WindowResidencyHosting)?

    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var clipboardWindows: [UUID: ClipboardWindowController] = [:]

    private static let logger = Logger(subsystem: "app.kernova", category: "AppWindowRegistry")

    init(viewModel: VMLibraryViewModel, displayPlacement: VMDisplayPlacementController) {
        self.viewModel = viewModel
        self.displayPlacement = displayPlacement
    }

    // MARK: - Library

    var libraryWindow: NSWindow? { mainWindowController?.window }

    /// The library's detail pane, which hosts a VM's inline display.
    var libraryDetailContainer: DetailContainerViewController? {
        mainWindowController?.detailContainer
    }

    /// Whether the library window has been dismissed (closed by the user).
    ///
    /// Distinguishes closed from hidden (Cmd+H) and minimized (Cmd+M).
    var isLibraryDismissed: Bool {
        guard let window = libraryWindow else { return false }
        if NSApp.isHidden || window.isMiniaturized { return false }
        return !window.isVisible
    }

    func showLibrary(bringToFront: Bool) {
        residency?.prepareToPresentWindow()
        if let existingWindow = mainWindowController?.window {
            if bringToFront {
                Self.logger.debug("showLibrary: focusing existing window")
                existingWindow.makeKeyAndOrderFront(nil)
            } else {
                Self.logger.debug("showLibrary: showing existing window in background")
                existingWindow.orderBack(nil)
            }
        } else {
            Self.logger.notice("showLibrary: recreating main window controller")
            let windowController = MainWindowController(viewModel: viewModel)
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

    // MARK: - Settings

    func showSettings(_ sender: Any?) {
        residency?.prepareToPresentWindow()
        let controller = settingsWindowController ?? SettingsWindowController(viewModel: viewModel)
        settingsWindowController = controller
        NSApp.activate()
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
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

        let controller = ClipboardWindowController(instance: instance, viewModel: viewModel)
        // Synchronous, unlike the display windows' deferred close handling, and
        // not because the closing window has left `NSApp.windows` — it has not,
        // so `hasUserWindow` still counts it through the untracked-panel scan.
        // Neither reconcile reads that here: the test host's `isIdle` reads
        // registry state only, and the resident app's `automationIdleOutcome`
        // short-circuits on the `hasPresentedInterface` latch
        // `AppResidencyController.prepareToPresentWindow()` set when this window
        // was shown.
        controller.onWillClose = { [weak self] in
            guard let self else { return }
            self.clipboardWindows.removeValue(forKey: vmID)
            self.residency?.reconcileIdleTermination()
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
        if onScreen(settingsWindowController?.window) { return true }
        return false
    }

    /// Whether any user-facing Kernova window is currently on screen, optionally
    /// counting a miniaturized one as present.
    ///
    /// Deliberately does NOT special-case `NSApp.isHidden`: plain ⌘H closes no
    /// window, so no reconcile fires and the Dock icon persists. Forcing
    /// `.regular` while hidden strands the agent with a Dock icon and zero
    /// windows when a background close (a VM shutting down empties the last
    /// display window mid-hide) fires the reconcile.
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

    /// Whether any window beyond the library and Settings is open.
    var hasAuxiliaryWindows: Bool {
        !displayPlacement.isEmpty || !clipboardWindows.isEmpty
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
        settingsWindowController?.window?.close()
        mainWindowController?.window?.close()
    }
}

// MARK: - VMDisplayPlacementHosting

extension AppWindowRegistry: VMDisplayPlacementHosting {
    var libraryScreen: NSScreen? { libraryWindow?.screen }
}
