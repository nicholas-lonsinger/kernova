import Cocoa
import KernovaCore
import KernovaLogging

/// The one owner of which user-facing windows exist, and whether any of them is
/// on screen.
///
/// Every window a person can see belongs here — the library, Settings, the
/// config check, the per-VM guest-agent status windows, and the
/// display windows
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

    private let stage: WindowStage
    /// The login session's focus, which a window the user asked for brings
    /// forward.
    let focus: any SessionFocus
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var guestAgentStatusWindows: [UUID: GuestAgentStatusWindowController] = [:]

    /// Reports that this registry put a window on screen — an event no
    /// notification carries for a window ordered in without becoming key.
    var onWindowShown: (@MainActor () -> Void)?
    /// Reports a window's `willClose`, once the window is out of
    /// ``alertScene()``.
    var onWindowWillClose: (@MainActor (NSWindow) -> Void)?

    /// The windows that began closing and that this registry has not shown
    /// since. A window still reads as visible for the whole of its close —
    /// sheets ending under it post their own events meanwhile — so this, not
    /// `isVisible`, is what keeps a closing window from taking an alert.
    private let closedWindows = NSHashTable<NSWindow>.weakObjects()
    private var willCloseObserver: (any NSObjectProtocol)?

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "AppWindowRegistry")

    init(
        viewModel: VMLibraryViewModel,
        displayPlacement: VMDisplayPlacementController,
        stage: WindowStage,
        focus: any SessionFocus
    ) {
        self.viewModel = viewModel
        self.displayPlacement = displayPlacement
        self.stage = stage
        self.focus = focus
        displayPlacement.host = self
        // Synchronous on the posting thread (`queue: nil`), so the window is
        // out of the scene before anything else hears of the close.
        willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.windowWillClose(window) }
        }
    }

    isolated deinit {
        if let willCloseObserver { NotificationCenter.default.removeObserver(willCloseObserver) }
    }

    private func windowWillClose(_ window: NSWindow) {
        closedWindows.add(window)
        onWindowWillClose?(window)
    }

    /// Reports that this registry put `window` on screen, making it an alert
    /// target again if it had closed.
    private func shown(_ window: NSWindow?) {
        if let window { closedWindows.remove(window) }
        onWindowShown?()
    }

    private func present(_ controller: NSWindowController, _ presentation: WindowPresentation) {
        guard let window = controller.window else { return }
        focus.present(window, presentation)
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
                Self.logger.log(.debug, "showLibrary: focusing existing window")
                focus.present(existingWindow, .keyAndFront)
            } else {
                Self.logger.log(.debug, "showLibrary: showing existing window in background")
                focus.present(existingWindow, .back)
            }
        } else {
            Self.logger.log(.notice, "showLibrary: recreating main window controller")
            let windowController = MainWindowController(
                viewModel: viewModel, stage: stage)
            present(windowController, bringToFront ? .keyAndFront : .back)
            mainWindowController = windowController
        }
        shown(mainWindowController?.window)
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
        guard let mainWindowController, let window = mainWindowController.window,
            focus.standing(of: window).isVisible
        else { return nil }
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
            ?? SettingsWindowController(viewModel: viewModel, stage: stage)
        settingsWindowController = controller
        if let destination { controller.tabs.show(destination) }
        focus.activate()
        present(controller, .keyAndFront)
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
            ?? ConfigCheckWindowController(viewModel: viewModel, stage: stage)
        configCheckWindowController = controller
        switch request {
        case .user:
            focus.activate()
            present(controller, .keyAndFront)
        case .automatic:
            present(controller, .front)
        }
        controller.checkAgain()
    }

    // MARK: - Guest Agent Status

    /// Shows or focuses the guest-agent status window for `instance`, when the
    /// VM's state admits one.
    func showGuestAgentStatus(for instance: VMInstance) {
        guard viewModel.capabilities.accepts(.showGuestAgentStatus, on: instance) else { return }
        let vmID = instance.instanceID
        if let existing = guestAgentStatusWindows[vmID] {
            residency?.prepareToPresentWindow()
            present(existing, .keyAndFront)
            shown(existing.window)
            return
        }
        guard let controller = GuestAgentStatusWindowController(instance: instance, viewModel: viewModel, stage: stage)
        else { return }
        residency?.prepareToPresentWindow()
        controller.onWillClose = { [weak self] in
            self?.guestAgentStatusWindows.removeValue(forKey: vmID)
        }
        guestAgentStatusWindows[vmID] = controller
        present(controller, .keyAndFront)
        shown(controller.window)
    }

    func guestAgentStatusWindow(for vmID: UUID) -> NSWindow? { guestAgentStatusWindows[vmID]?.window }

    // MARK: - Working Window

    /// The VM `window` shows: a display or guest-agent status
    /// window's own VM, or the library's selection while the library window is
    /// visible; `nil` for any other window. A sheet answers for the window it
    /// is attached to.
    func instance(shownIn window: NSWindow) -> VMInstance? {
        let window = Self.sheetRoot(of: window)
        if let instance = ownInstance(of: window) { return instance }
        guard window === libraryWindow, focus.standing(of: window).isVisible else { return nil }
        return viewModel.selectedInstance
    }

    /// The VMs `window` can act on: a display or guest-agent status
    /// window's own VM, or every VM the library lists while the library window
    /// is visible — its sidebar acts on any of them, not only the selection. A
    /// sheet answers for the window it is attached to.
    func vmIDs(actedOnIn window: NSWindow) -> Set<UUID> {
        let window = Self.sheetRoot(of: window)
        if let instance = ownInstance(of: window) { return [instance.id] }
        guard window === libraryWindow, focus.standing(of: window).isVisible else { return [] }
        return Set(viewModel.instances.map(\.id))
    }

    /// The VM a display or guest-agent status window belongs to.
    private func ownInstance(of window: NSWindow) -> VMInstance? {
        displayPlacement.instance(forDisplayWindow: window)
            ?? guestAgentStatusWindows.values.first { $0.window === window }?.instance
    }

    /// The window the user is working in: the key window, else the main one.
    var workingWindow: NSWindow? { focus.keyWindow ?? focus.mainWindow }

    /// The VM the user is working on, in the session's key and main windows.
    var workingInstance: VMInstance? {
        workingInstance(keyWindow: focus.keyWindow, mainWindow: focus.mainWindow)
    }

    /// The VM the user is working on, found the way AppKit finds a menu
    /// action's target — the key window's VM, else the main window's
    /// (`NSApplication.sendAction(_:to:from:)`).
    func workingInstance(keyWindow: NSWindow?, mainWindow: NSWindow?) -> VMInstance? {
        keyWindow.flatMap(instance(shownIn:)) ?? mainWindow.flatMap(instance(shownIn:))
    }

    /// The windows an alert can go to now, from the session's key and main
    /// windows.
    func alertScene() -> AlertWindowScene<NSWindow> {
        alertScene(keyWindow: focus.keyWindow, mainWindow: focus.mainWindow)
    }

    /// The windows an alert can go to, read from the key and main windows the
    /// caller passes and the library and display windows this registry holds.
    /// A window that began closing takes no alert until this registry shows it
    /// again.
    func alertScene(keyWindow: NSWindow?, mainWindow: NSWindow?) -> AlertWindowScene<NSWindow> {
        let working = [keyWindow, mainWindow].compactMap { $0 }.map { window in
            (window: Self.sheetRoot(of: window), vmIDs: vmIDs(actedOnIn: window))
        }
        let displayWindows = displayPlacement.windowsByVM
        var states: [NSWindow: WindowStanding] = [:]
        for window in working.map(\.window) + displayWindows.values + [libraryWindow].compactMap({ $0 })
        where !closedWindows.contains(window) {
            states[window] = focus.standing(of: window)
        }
        return AlertWindowScene(
            working: working, displayWindows: displayWindows, library: libraryWindow, states: states)
    }

    /// The window `window` is a sheet on, through every level, or `window`
    /// itself.
    private static func sheetRoot(of window: NSWindow) -> NSWindow {
        var window = window
        while let parent = window.sheetParent { window = parent }
        return window
    }

    // MARK: - Presence

    /// Whether any window this registry tracks is on screen, counting a
    /// miniaturized one as present.
    var hasTrackedUserWindow: Bool {
        func isPresent(_ window: NSWindow?) -> Bool {
            guard let window else { return false }
            return focus.standing(of: window).isPresent
        }
        if isPresent(libraryWindow) { return true }
        if displayPlacement.hasWindow(where: { isPresent($0) }) { return true }
        if guestAgentStatusWindows.values.contains(where: { isPresent($0.window) }) { return true }
        if isPresent(settingsWindow) { return true }
        if isPresent(configCheckWindow) { return true }
        return false
    }

    /// Whether any user-facing Kernova window is currently on screen, counting
    /// a miniaturized one as present.
    ///
    /// Does NOT special-case `NSApp.isHidden`, which turns every window's
    /// `isVisible` false without closing one: this answers what is on screen,
    /// and hiding is a term of the residency decision instead — see
    /// ``AppResidencyPolicy/residencyOutcome(hasVisibleUserWindow:isHidden:keepInMenuBar:hasUninterruptibleWork:)``.
    var hasUserWindow: Bool {
        if hasTrackedUserWindow { return true }
        // Untracked AppKit-owned panels are genuine on-screen windows: count them
        // so a reconcile can't strip the Dock icon while one is the last visible.
        return stage.windows().contains { window in
            Self.isUntrackedUserPanel(
                level: window.level, styleMask: window.styleMask, standing: focus.standing(of: window))
        }
    }

    /// Whether a window at `level` with `styleMask`, standing as `standing`, is
    /// an untracked, AppKit-owned top-level panel whose presence must keep the
    /// Dock icon.
    ///
    /// The standard About panel is the motivating example. The visible +
    /// normal-level + titled filter excludes chrome: the status item's backing
    /// `NSStatusBarWindow` is borderless and sits above `.normal`, so an
    /// unfiltered scan of the app's windows would pin the agent to `.regular`
    /// forever.
    nonisolated static func isUntrackedUserPanel(
        level: NSWindow.Level, styleMask: NSWindow.StyleMask, standing: WindowStanding
    ) -> Bool {
        standing.isPresent && level == .normal && styleMask.contains(.titled)
    }

    // MARK: - Pending Edits

    /// Commits the text edit open in each window on this registry's stage
    /// (``PendingFieldEdits/save(in:)``).
    func savePendingEdits() {
        PendingFieldEdits.save(in: stage.windows())
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
        for controller in Array(guestAgentStatusWindows.values) { controller.window?.close() }
        settingsWindow?.close()
        configCheckWindow?.close()
        mainWindowController?.window?.close()
    }
}

// MARK: - VMDisplayPlacementHosting

extension AppWindowRegistry: VMDisplayPlacementHosting {
    var libraryScreen: NSScreen? { libraryWindow?.screen }

    func displayWindowShown(_ window: NSWindow) { shown(window) }
}
