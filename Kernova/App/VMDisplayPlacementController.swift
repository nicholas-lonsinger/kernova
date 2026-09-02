import Cocoa
import os

/// The window seams a ``VMDisplayPlacementController`` needs but cannot own.
@MainActor
protocol VMDisplayPlacementHosting: AnyObject {
    /// The screen the library window is on, or nil when it has none.
    var libraryScreen: NSScreen? { get }
    func showLibrary(bringToFront: Bool)
}

/// The one owner of where each VM's display lives.
///
/// Holds the display-window registry and is the sole writer of both placement
/// fields — the runtime ``VMInstance/displayMode`` and the persisted
/// ``VMConfiguration/displayPreference`` — for every transition.
/// ``VMDisplayWindowController`` is a view under it: it reports what AppKit did
/// and writes neither field.
@MainActor
final class VMDisplayPlacementController {
    /// Why a display window is closing.
    enum CloseReason: Equatable {
        /// The user closed the window (red button / ⌘W): the VM keeps running
        /// headless — nothing pops back into the main window.
        case userClose
        /// App-initiated dismissal — the VM stopped/errored/cold-paused out
        /// from under the window, or the whole GUI is being dismissed.
        case appDismissal
        /// Explicit Pop In: the display returns to the main window's detail
        /// pane and `displayPreference` reverts to `.inline`.
        case popIn
    }

    /// A change in where a VM's display lives.
    enum DisplayTransition: Equatable {
        /// A display window was put on screen, in the style the request asked for.
        case shown(fullscreen: Bool)
        case enteredFullscreen
        case exitedFullscreen
        case closed(CloseReason)
    }

    /// The app-level work a transition owes once the window list has settled.
    enum FollowUp: Equatable {
        case none
        /// Re-decide whether a process nobody is watching still has work.
        case idleReconcile
        /// Bring the library back so the popped-in display is visible.
        case restoreLibrary
    }

    /// Where a transition leaves the VM's display.
    struct Placement: Equatable {
        /// The runtime hosting the VM lands in.
        let mode: VMDisplayMode
        /// The preference to persist, or `nil` to leave the persisted one alone.
        let persistPreference: VMDisplayPreference?
        let followUp: FollowUp
    }

    /// What "Pop Out Display" does, given the VM's current placement.
    enum PopOutAction: Equatable {
        /// A window is open: close it, which pops the display back in.
        case closeWindowForPopIn
        /// The VM runs headless with no window: return the display slot directly.
        case popInFromHeadless
        /// The display is inline: detach it into a window.
        case popOut
    }

    /// How a pop-in restores the library window.
    enum LibraryRestore: Equatable {
        /// The user popped in from the display window — focus the library.
        case focusLibrary
        /// The pop-in happened while Kernova was not active — show the library
        /// without stealing focus from the app the user is in.
        case showInBackground
        /// The user is already in another Kernova window.
        case none
    }

    private let viewModel: VMLibraryViewModel
    weak var host: (any VMDisplayPlacementHosting)?
    /// The residency decisions a display window's placement needs but cannot
    /// make.
    weak var residency: (any WindowResidencyHosting)?
    private var windows: [UUID: VMDisplayWindowController] = [:]
    /// The reason recorded for a programmatic close, from the moment it is
    /// requested until the close has been fully handled.
    private var pendingCloseReasons: [UUID: CloseReason] = [:]

    private static let logger = Logger(subsystem: "app.kernova", category: "VMDisplayPlacementController")

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Deciders

    /// Decides what "Pop Out Display" does for a VM.
    nonisolated static func popOutAction(hasWindow: Bool, mode: VMDisplayMode) -> PopOutAction {
        if hasWindow { return .closeWindowForPopIn }
        return mode == .hidden ? .popInFromHeadless : .popOut
    }

    /// Decides where a transition leaves the display, and what the app owes
    /// afterwards.
    ///
    /// A `nil` `persistPreference` leaves the persisted value alone: the open
    /// path persisted the user's choice at the request site, and a close that
    /// is not a pop-in must keep the style the next reopen restores.
    nonisolated static func placement(for transition: DisplayTransition) -> Placement {
        switch transition {
        case .shown(let fullscreen):
            Placement(
                mode: fullscreen ? .fullscreen : .popOut, persistPreference: nil, followUp: .none)
        case .enteredFullscreen:
            Placement(mode: .fullscreen, persistPreference: .fullscreen, followUp: .none)
        case .exitedFullscreen:
            Placement(mode: .popOut, persistPreference: .popOut, followUp: .none)
        case .closed(.userClose):
            Placement(mode: .hidden, persistPreference: nil, followUp: .none)
        case .closed(.appDismissal):
            Placement(mode: .inline, persistPreference: nil, followUp: .idleReconcile)
        case .closed(.popIn):
            Placement(mode: .inline, persistPreference: .inline, followUp: .restoreLibrary)
        }
    }

    /// Decides how a pop-in brings the library back.
    nonisolated static func libraryRestore(
        wasKeyWindow: Bool, appWasActive: Bool
    ) -> LibraryRestore {
        if wasKeyWindow && appWasActive { return .focusLibrary }
        if !appWasActive { return .showInBackground }
        return .none
    }

    // MARK: - Registry

    func window(for vmID: UUID) -> NSWindow? { windows[vmID]?.window }

    /// The VM whose display window is `window`, if any.
    func instance(forKeyWindow window: NSWindow) -> VMInstance? {
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
            enterFullscreen: instance.configuration.displayPreference == .fullscreen)
    }

    func togglePopOut(for instance: VMInstance) {
        switch Self.popOutAction(
            hasWindow: windows[instance.instanceID] != nil, mode: instance.displayMode)
        {
        case .closeWindowForPopIn:
            popIn(instance)
        case .popInFromHeadless:
            // There is no window to close — just return the display slot to the
            // main window.
            viewModel.updateConfiguration(of: instance) { $0.displayPreference = .inline }
            instance.displayMode = .inline
            viewModel.presenter?.focusGuestDisplay(for: instance)
        case .popOut:
            viewModel.updateConfiguration(of: instance) { $0.displayPreference = .popOut }
            openDisplayWindow(for: instance, enterFullscreen: false)
        }
    }

    func toggleFullscreen(for instance: VMInstance) {
        if let existing = windows[instance.instanceID] {
            existing.window?.toggleFullScreen(nil)
            return
        }
        viewModel.updateConfiguration(of: instance) { $0.displayPreference = .fullscreen }
        openDisplayWindow(for: instance, enterFullscreen: true)
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
    private func requestClose(of vmID: UUID, reason: CloseReason) {
        guard let controller = windows[vmID], pendingCloseReasons[vmID] == nil else { return }
        pendingCloseReasons[vmID] = reason
        controller.closeFromOwner()
    }

    private func openDisplayWindow(for instance: VMInstance, enterFullscreen: Bool) {
        let vmID = instance.instanceID

        // Already open (e.g. resuming a live-paused VM from the library):
        // surface the existing window so keyboard input lands in the guest.
        if let existing = windows[vmID] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        residency?.prepareToPresentWindow()

        let controller = VMDisplayWindowController(
            instance: instance,
            capabilities: viewModel.capabilities,
            enterFullscreen: enterFullscreen,
            onResume: { [weak self] in
                guard let self else { return }
                Task { await self.viewModel.resume(instance) }
            }
        )
        controller.onEnteredFullscreen = { [weak self] in
            self?.apply(Self.placement(for: .enteredFullscreen), to: instance)
        }
        controller.onExitedFullscreen = { [weak self] in
            // The mode is what says the window was in fullscreen to begin with.
            guard instance.displayMode == .fullscreen else { return }
            self?.apply(Self.placement(for: .exitedFullscreen), to: instance)
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

        apply(Self.placement(for: .shown(fullscreen: enterFullscreen)), to: instance)
        controller.showWindow(nil)
    }

    /// The best screen for entering fullscreen: the display the VM was last
    /// fullscreen on, else the library window's display, else the primary.
    ///
    /// Reads `lastFullscreenDisplayID`, which ``handleClose(of:context:)`` is the
    /// only writer of.
    func preferredScreenForFullscreen(of instance: VMInstance) -> NSScreen? {
        if let savedID = instance.configuration.lastFullscreenDisplayID {
            if let target = NSScreen.screens.first(where: { $0.displayID == savedID }) {
                Self.logger.debug(
                    "preferredScreenForFullscreen for '\(instance.name, privacy: .public)': using saved display \(savedID, privacy: .public)"
                )
                return target
            }
            Self.logger.debug(
                "preferredScreenForFullscreen for '\(instance.name, privacy: .public)': saved display \(savedID, privacy: .public) not found, falling back"
            )
        }
        if let libraryScreen = host?.libraryScreen {
            return libraryScreen
        }
        return NSScreen.screens.first
    }

    // MARK: - Transition Handling

    private func apply(_ placement: Placement, to instance: VMInstance) {
        instance.displayMode = placement.mode
        if let preference = placement.persistPreference {
            viewModel.updateConfiguration(of: instance) { $0.displayPreference = preference }
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
        let placement = Self.placement(for: .closed(reason))
        instance.displayMode = placement.mode

        Task { @MainActor in
            self.pendingCloseReasons.removeValue(forKey: vmID)
            guard self.windows.removeValue(forKey: vmID) != nil else { return }

            self.viewModel.updateConfiguration(of: instance) { config in
                if let displayID = context.lastDisplayID {
                    config.lastFullscreenDisplayID = displayID
                }
                if let preference = placement.persistPreference {
                    config.displayPreference = preference
                }
            }
            Self.logger.notice(
                "Display window closed for '\(instance.name, privacy: .public)' (reason=\(String(describing: reason), privacy: .public), policy=\(NSApp.activationPolicy().rawValue, privacy: .public))"
            )

            switch placement.followUp {
            case .none:
                break
            case .idleReconcile:
                self.residency?.reconcileIdleTermination()
            case .restoreLibrary:
                self.viewModel.selectedID = vmID
                switch Self.libraryRestore(
                    wasKeyWindow: context.wasKeyWindow, appWasActive: context.appWasActive)
                {
                case .focusLibrary:
                    self.host?.showLibrary(bringToFront: true)
                case .showInBackground:
                    self.host?.showLibrary(bringToFront: false)
                case .none:
                    break
                }
                self.viewModel.presenter?.focusGuestDisplay(for: instance)
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
