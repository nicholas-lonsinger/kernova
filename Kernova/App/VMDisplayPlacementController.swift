import Cocoa
import KernovaLogging

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
/// ``VMHostState/displayPreference`` — for every transition.
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

    /// How a display window goes on screen.
    enum WindowShow: Equatable {
        /// Key and frontmost, in fullscreen when asked for it.
        case front(fullscreen: Bool)
        /// Ordered into Kernova's own window layer, taking neither key nor the
        /// screen from the app the user is in.
        case behind
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
    private let autosaveScope: WindowAutosaveScope
    weak var host: (any VMDisplayPlacementHosting)?
    /// The residency decisions a display window's placement needs but cannot
    /// make.
    weak var residency: (any WindowResidencyHosting)?
    private var windows: [UUID: VMDisplayWindowController] = [:]
    /// The reason recorded for a programmatic close, from the moment it is
    /// requested until the close has been fully handled.
    private var pendingCloseReasons: [UUID: CloseReason] = [:]

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMDisplayPlacementController")

    init(viewModel: VMLibraryViewModel, autosaveScope: WindowAutosaveScope) {
        self.viewModel = viewModel
        self.autosaveScope = autosaveScope
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
            Placement(mode: .inline, persistPreference: nil, followUp: .none)
        case .closed(.popIn):
            Placement(mode: .inline, persistPreference: .inline, followUp: .restoreLibrary)
        }
    }

    /// How a bring-up readies this VM's display, or `nil` when it readies
    /// nothing.
    ///
    /// Two VMs get nothing. An inline one shows in whichever row is selected,
    /// and a bring-up does not change the user's selection. And an app that is
    /// presenting no GUI was asked not to have one — a window here would hand
    /// it the Dock icon and menu bar it came up without.
    ///
    /// A bring-up is not a request to look at the guest, so the window takes
    /// key and the screen only where the user is already in Kernova. From
    /// another app it goes up behind what they are looking at, which is also
    /// why fullscreen is reserved for the foreground: entering it moves the
    /// user to a Space they did not ask for.
    nonisolated static func readying(
        preference: VMDisplayPreference, posture: GUIPosture
    ) -> WindowShow? {
        guard preference != .inline else { return nil }
        switch posture {
        case .absent: return nil
        case .background: return .behind
        case .foreground: return .front(fullscreen: preference == .fullscreen)
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
    func readyDisplay(for instance: VMInstance) {
        guard
            let show = Self.readying(
                preference: instance.hostState.displayPreference,
                posture: residency?.guiPosture ?? .absent)
        else { return }
        guard windows[instance.instanceID] == nil else { return }
        openDisplayWindow(for: instance, show: show)
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
            viewModel.updateSettings(of: instance) { $0.hostState.displayPreference = .inline }
            instance.displayMode = .inline
            viewModel.presenter?.focusGuestDisplay(for: instance)
        case .popOut:
            viewModel.updateSettings(of: instance) { $0.hostState.displayPreference = .popOut }
            openDisplayWindow(for: instance, show: .front(fullscreen: false))
        }
    }

    func toggleFullscreen(for instance: VMInstance) {
        if let existing = windows[instance.instanceID] {
            existing.window?.toggleFullScreen(nil)
            return
        }
        viewModel.updateSettings(of: instance) { $0.hostState.displayPreference = .fullscreen }
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
    private func requestClose(of vmID: UUID, reason: CloseReason) {
        guard let controller = windows[vmID], pendingCloseReasons[vmID] == nil else { return }
        pendingCloseReasons[vmID] = reason
        controller.closeFromOwner()
    }

    private func openDisplayWindow(for instance: VMInstance, show: WindowShow) {
        let vmID = instance.instanceID
        let enterFullscreen = show == .front(fullscreen: true)

        // Already open (e.g. resuming a live-paused VM from the library):
        // surface the existing window so keyboard input lands in the guest.
        if let existing = windows[vmID] {
            switch show {
            case .front: existing.window?.makeKeyAndOrderFront(nil)
            case .behind: existing.window?.orderFront(nil)
            }
            return
        }
        residency?.prepareToPresentWindow()

        let controller = VMDisplayWindowController(
            instance: instance,
            capabilities: viewModel.capabilities,
            enterFullscreen: enterFullscreen,
            autosaveScope: autosaveScope,
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
        switch show {
        case .front: controller.showWindow(nil)
        case .behind: controller.showWindowBehind()
        }
    }

    /// The best screen for entering fullscreen: the display the VM was last
    /// fullscreen on, else the library window's display, else the primary.
    ///
    /// Reads `lastFullscreenDisplayID`, which ``handleClose(of:context:)`` is the
    /// only writer of.
    func preferredScreenForFullscreen(of instance: VMInstance) -> NSScreen? {
        if let savedID = instance.hostState.lastFullscreenDisplayID {
            if let target = NSScreen.screens.first(where: { $0.displayID == savedID }) {
                #log(
                    Self.logger, .debug,
                    "preferredScreenForFullscreen for '\(instance.name, privacy: .public)': using saved display \(savedID, privacy: .public)"
                )
                return target
            }
            #log(
                Self.logger, .debug,
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
            viewModel.updateSettings(of: instance) { $0.hostState.displayPreference = preference }
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

            self.viewModel.updateSettings(of: instance) { settings in
                if let displayID = context.lastDisplayID {
                    settings.hostState.lastFullscreenDisplayID = displayID
                }
                if let preference = placement.persistPreference {
                    settings.hostState.displayPreference = preference
                }
            }
            #log(
                Self.logger, .notice,
                "Display window closed for '\(instance.name, privacy: .public)' (reason=\(String(describing: reason), privacy: .public), policy=\(NSApp.activationPolicy().rawValue, privacy: .public))"
            )

            switch placement.followUp {
            case .none:
                break
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
