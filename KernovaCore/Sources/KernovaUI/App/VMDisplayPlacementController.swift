import Cocoa
import KernovaCore
import KernovaKit
import KernovaLogging

/// The window seams a ``VMDisplayPlacementController`` needs but cannot own.
@MainActor
protocol VMDisplayPlacementHosting: AnyObject {
    /// The screen the library window is on, or nil when it has none.
    var libraryScreen: NSScreen? { get }
    func showLibrary(bringToFront: Bool)
    /// `window`, a display window, was put on screen.
    func displayWindowShown(_ window: NSWindow)
    /// The app's activation policy and activation.
    var presence: any AppPresence { get }
}

/// The one owner of where each VM's display lives.
///
/// Holds the display-window registry and decides both placement fields — the
/// runtime ``VMInstance/displayMode`` and the persisted
/// ``VMHostState/displayPreference``, written through its key — for every
/// transition.
/// ``VMDisplayWindowController`` is a view under it: it reports what AppKit did
/// and writes neither field.
@MainActor
final class VMDisplayPlacementController {
    private let viewModel: VMLibraryViewModel
    private let stage: WindowStage
    weak var host: (any VMDisplayPlacementHosting)?
    /// The residency decisions a display window's placement needs but cannot
    /// make.
    weak var residency: (any WindowResidencyHosting)?
    private var windows: [UUID: VMDisplayWindowController] = [:]
    /// The reason recorded for a programmatic close, from the moment it is
    /// requested until the close has been fully handled.
    private var pendingCloseReasons: [UUID: VMDisplayPlacement.CloseReason] = [:]

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMDisplayPlacementController")

    init(viewModel: VMLibraryViewModel, stage: WindowStage) {
        self.viewModel = viewModel
        self.stage = stage
    }

    // MARK: - Registry

    func window(for vmID: UUID) -> NSWindow? { windows[vmID]?.window }

    /// Every display window, by its VM's id.
    var windowsByVM: [UUID: NSWindow] { windows.compactMapValues(\.window) }

    /// The VM whose display window is `window`, if any.
    func instance(forDisplayWindow window: NSWindow) -> VMInstance? {
        windows.values.first(where: { $0.window === window })?.instance
    }

    func hasWindow(where predicate: (NSWindow) -> Bool) -> Bool {
        windows.values.contains { $0.window.map(predicate) ?? false }
    }

    /// Whether `window` is a display window closing because the user popped it
    /// back into the library, which owns the reconcile for that close.
    func isPoppingIn(_ window: NSWindow) -> Bool {
        windows.contains { vmID, controller in
            controller.window === window && pendingCloseReasons[vmID] == .popIn
        }
    }

    // MARK: - Commands

    /// Brings the VM's display window forward, opening it in its persisted
    /// style when the user previously closed it while the VM ran headless.
    func showDisplayWindow(for instance: VMInstance) {
        openDisplayWindow(
            for: instance,
            show: .front(fullscreen: instance.hostState.displayPreference == .fullscreen))
    }

    /// Readies a VM's display for a bring-up: opens its window when it has none,
    /// and leaves one already open exactly where it is.
    ///
    /// Not ``showDisplayWindow(for:)``: readying is not surfacing, so a
    /// bring-up reaching a Kernova the user is not in puts the window up
    /// behind what they are looking at — and a fullscreen VM readied that way
    /// runs in a pop-out window, its persisted preference untouched, until the
    /// user brings it forward and enters fullscreen themselves.
    func readyDisplay(for instance: VMInstance, presence: VMBringUpPresence) {
        guard
            let show = VMDisplayPlacement.readying(
                preference: instance.hostState.displayPreference,
                posture: residency?.guiPosture ?? .absent, presence: presence)
        else { return }
        guard windows[instance.instanceID] == nil else { return }
        openDisplayWindow(for: instance, show: show)
    }

    func togglePopOut(for instance: VMInstance) {
        switch VMDisplayPlacement.popOutAction(
            hasWindow: windows[instance.instanceID] != nil, mode: instance.displayMode)
        {
        case .closeWindowForPopIn:
            popIn(instance)
        case .popInFromHeadless:
            // There is no window to close — just return the display slot to the
            // main window.
            persist(.inline, for: instance)
            instance.displayMode = .inline
            viewModel.libraryWindowPresenter?.focusGuestDisplay(for: instance)
        case .popOut:
            persist(.popOut, for: instance)
            openDisplayWindow(for: instance, show: .front(fullscreen: false))
        }
    }

    func toggleFullscreen(for instance: VMInstance) {
        if let existing = windows[instance.instanceID] {
            existing.window?.toggleFullScreen(nil)
            return
        }
        persist(.fullscreen, for: instance)
        openDisplayWindow(for: instance, show: .front(fullscreen: true))
    }

    /// Closes the VM's display window as an explicit Pop In.
    func popIn(_ instance: VMInstance) {
        requestClose(of: instance.instanceID, reason: .popIn)
    }

    /// Closes the VM's display window as an app-initiated dismissal, so the
    /// display slot returns to the main window rather than going headless.
    func dismiss(_ vmID: UUID) {
        requestClose(of: vmID, reason: .appDismissal)
    }

    /// Dismisses every open display window.
    ///
    /// The keys are snapshotted so the loop stands independent of each close's
    /// deferred phase, which removes the registry entry a runloop turn later.
    func closeAllForAppDismissal() {
        for vmID in Array(windows.keys) { dismiss(vmID) }
    }

    /// Records the reason before asking the window to close, so the close
    /// handler never has to read a token back out of the view.
    ///
    /// The pending reason is also the idempotence guard: the window
    /// controller's observation reports a dismissal on every tick while the VM
    /// is stopped.
    private func requestClose(of vmID: UUID, reason: VMDisplayPlacement.CloseReason) {
        guard let controller = windows[vmID], pendingCloseReasons[vmID] == nil else { return }
        pendingCloseReasons[vmID] = reason
        controller.closeFromOwner()
    }

    private func openDisplayWindow(for instance: VMInstance, show: VMDisplayPlacement.WindowShow) {
        let vmID = instance.instanceID
        let enterFullscreen = show == .front(fullscreen: true)

        // Already open (e.g. resuming a live-paused VM from the library):
        // surface the existing window so keyboard input lands in the guest.
        if let existing = windows[vmID] {
            switch show {
            case .front: existing.window?.makeKeyAndOrderFront(nil)
            case .behind: existing.window?.orderFront(nil)
            }
            if let window = existing.window { host?.displayWindowShown(window) }
            return
        }
        residency?.prepareToPresentWindow()

        let controller = VMDisplayWindowController(
            instance: instance,
            capabilities: viewModel.capabilities,
            enterFullscreen: enterFullscreen,
            stage: stage,
            onResume: { [weak self] in
                guard let self else { return }
                Task { await self.viewModel.resume(instance) }
            }
        )
        controller.onEnteredFullscreen = { [weak self] in
            self?.apply(VMDisplayPlacement.placement(for: .enteredFullscreen), to: instance)
        }
        controller.onExitedFullscreen = { [weak self] in
            // The mode is what says the window was in fullscreen to begin with.
            guard instance.displayMode == .fullscreen else { return }
            self?.apply(VMDisplayPlacement.placement(for: .exitedFullscreen), to: instance)
        }
        controller.onWillClose = { [weak self] context in
            self?.handleClose(of: instance, context: context)
        }
        controller.onRequestDismissal = { [weak self] in
            self?.dismiss(vmID)
        }
        windows[vmID] = controller

        // For fullscreen: position on the remembered display so toggleFullScreen
        // picks the correct screen.
        if enterFullscreen {
            if let screen = preferredScreenForFullscreen(of: instance),
                let window = controller.window
            {
                let frame = screen.frame
                let centeredOrigin = NSPoint(
                    x: frame.midX - window.frame.width / 2,
                    y: frame.midY - window.frame.height / 2
                )
                window.setFrameOrigin(centeredOrigin)
            }
        }

        apply(VMDisplayPlacement.placement(for: .shown(fullscreen: enterFullscreen)), to: instance)
        switch show {
        case .front: controller.showWindow(nil)
        case .behind: controller.showWindowBehind()
        }
        if let window = controller.window { host?.displayWindowShown(window) }
    }

    /// The screen ``VMDisplayPlacement/fullscreenScreen(lastDisplayID:screens:libraryScreen:displayID:)``
    /// picks among the connected ones.
    ///
    /// Reads `lastFullscreenDisplayID`, which ``handleClose(of:context:)`` is the
    /// only writer of.
    func preferredScreenForFullscreen(of instance: VMInstance) -> NSScreen? {
        let lastDisplayID = instance.hostState.lastFullscreenDisplayID
        let screen = VMDisplayPlacement.fullscreenScreen(
            lastDisplayID: lastDisplayID, screens: NSScreen.screens, libraryScreen: host?.libraryScreen,
            displayID: \.displayID)
        if let lastDisplayID, screen?.displayID != lastDisplayID {
            #log(
                Self.logger, .debug,
                "preferredScreenForFullscreen for '\(instance.name, privacy: .public)': saved display \(lastDisplayID, privacy: .public) not found, falling back"
            )
        }
        return screen
    }

    // MARK: - Transition Handling

    /// Persists where `instance`'s display opens, through the
    /// `display.preference` key.
    private func persist(_ preference: VMDisplayPreference, for instance: VMInstance) {
        viewModel.setConfiguration(
            [VMConfigurationKeyRegistry.displayPreference.assigning(preference.rawValue)],
            on: instance)
    }

    private func apply(_ placement: VMDisplayPlacement.Placement, to instance: VMInstance) {
        instance.displayMode = placement.mode
        if let preference = placement.persistPreference {
            persist(preference, for: instance)
        }
    }

    /// Handles a display window's close, in the two phases the close requires.
    ///
    /// The runtime mode is written synchronously, while the notification is
    /// still dispatching: the detail pane's placeholder reads it, and the
    /// registry entry has to survive the dispatch so the app's global
    /// `willClose` observer can still recognize a pop-in.
    ///
    /// Everything else is deferred to the next runloop turn, once the closing
    /// window has left `NSApp.windows`: run during `willClose` the window still
    /// reports itself visible, so the activation-policy reconcile would keep the
    /// Dock icon and the idle reconcile would skip a quit it owes.
    private func handleClose(
        of instance: VMInstance, context: VMDisplayWindowController.CloseContext
    ) {
        let vmID = instance.instanceID
        let reason = pendingCloseReasons[vmID] ?? .userClose
        let placement = VMDisplayPlacement.placement(for: .closed(reason))
        instance.displayMode = placement.mode
        let appWasActive = host?.presence.isActive ?? false

        Task { @MainActor in
            self.pendingCloseReasons.removeValue(forKey: vmID)
            guard self.windows.removeValue(forKey: vmID) != nil else { return }

            if let displayID = context.lastDisplayID {
                self.viewModel.recordLastFullscreenDisplay(displayID, for: instance)
            }
            if let preference = placement.persistPreference {
                self.persist(preference, for: instance)
            }
            let policy = self.host.map { String($0.presence.activationPolicy.rawValue) } ?? "-"
            #log(
                Self.logger, .notice,
                "Display window closed for '\(instance.name, privacy: .public)' (reason=\(String(describing: reason), privacy: .public), policy=\(policy, privacy: .public))"
            )

            switch placement.followUp {
            case .none:
                break
            case .restoreLibrary:
                self.viewModel.selectRevealing(vmID)
                switch VMDisplayPlacement.libraryRestore(
                    wasKeyWindow: context.wasKeyWindow, appWasActive: appWasActive)
                {
                case .focusLibrary:
                    self.host?.showLibrary(bringToFront: true)
                case .showInBackground:
                    self.host?.showLibrary(bringToFront: false)
                case .none:
                    break
                }
                self.viewModel.libraryWindowPresenter?.focusGuestDisplay(for: instance)
                // Reconcile synchronously here, after the restore, rather than
                // through the app's scheduled sync: the global `willClose`
                // observer's independent `Task` isn't guaranteed to run after the
                // restore above, which would flip the Dock icon to `.accessory`
                // and back.
                self.residency?.syncActivationPolicy()
            }
        }
    }
}
