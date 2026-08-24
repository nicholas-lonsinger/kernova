import Cocoa
import os

/// Manages a dedicated window displaying a single VM's screen, either as a
/// resizable pop-out window or in native macOS fullscreen.
///
/// On show the inline display in the main window is replaced by a placeholder
/// (via `VMInstance.displayMode`). What happens on close depends on the
/// `CloseReason`: a user close leaves the VM running headless (`displayMode ==
/// .hidden`), while pop-in and app dismissal return the display slot to the
/// main window.
@MainActor
final class VMDisplayWindowController: NSWindowController, NSWindowDelegate {
    /// Why the display window is closing; `nil` while it is open.
    enum CloseReason {
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

    let vmID: UUID
    private(set) var closeReason: CloseReason?
    private(set) var lastDisplayID: CGDirectDisplayID?
    let instance: VMInstance
    private let toolbarManager: VMToolbarManager
    private let enterFullscreen: Bool
    private let onUpdateConfiguration: ((inout VMConfiguration) -> Void) -> Void
    private let backingView: VMDisplayBackingView
    private var instanceObservation: ObservationLoop?

    private static let logger = Logger(subsystem: "app.kernova", category: "VMDisplayWindowController")

    init(
        instance: VMInstance, enterFullscreen: Bool, onResume: @escaping () -> Void,
        onUpdateConfiguration: @escaping ((inout VMConfiguration) -> Void) -> Void
    ) {
        self.vmID = instance.instanceID
        self.instance = instance
        self.toolbarManager = VMToolbarManager(
            configuration: .init(
                lifecycleID: NSToolbarItem.Identifier("displayLifecycle"),
                saveStateID: NSToolbarItem.Identifier("displaySaveState"),
                // Targets this window's VM: the nil-target showClipboard action
                // resolves through `AppDelegate.activeInstance`, which prefers the
                // key display window's instance over the sidebar selection.
                clipboardID: NSToolbarItem.Identifier("displayClipboard"),
                popOutID: NSToolbarItem.Identifier("displayPopOut"),
                fullscreenID: NSToolbarItem.Identifier("displayFullscreen"),
                settingsToggleID: nil,
                checksPreparing: false,
                gatesDisplayOnCapability: false
            ),
            instanceProvider: { [weak instance] in instance }
        )
        self.enterFullscreen = enterFullscreen
        self.onUpdateConfiguration = onUpdateConfiguration

        let backing = VMDisplayBackingView()
        backing.onResume = onResume
        backing.dropAvailability = { [weak instance] in
            instance?.displayDropAvailability ?? .none
        }
        backing.onDropFiles = { [weak instance] urls, stagedIn in
            instance?.sendDroppedFilesToGuest(urls, stagedIn: stagedIn) ?? false
        }
        backing.onDropUnreadable = { [weak instance] in
            instance?.reportUnreadableDropToGuest()
        }
        backing.applyDropRegistration()
        backing.update(
            display: instance.session?.displayHandle,
            isPaused: instance.status == .paused,
            transitionText: instance.status.transitionLabel,
            automaticallyReconfiguresDisplay: instance.configuration.displayAutoResizes
        )
        self.backingView = backing

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = backing
        window.title = "\(instance.name) — Display"
        window.minSize = NSSize(width: 640, height: 400)
        window.collectionBehavior = [.fullScreenPrimary]

        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("VMDisplay-\(instance.instanceID)")

        // RATIONALE: one shared toolbar identifier for every VM's display window,
        // unlike the per-VM frame autosave name above — AppKit synchronizes
        // same-identifier toolbars, so a customized layout applies to all display
        // windows and persists as a single configuration.
        let toolbar = NSToolbar(identifier: "KernovaVMDisplayToolbar")
        toolbar.delegate = self
        // The autosaved configuration is restored when the toolbar is attached to
        // the window, so every property must be set before the attach below.
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func showWindow(_ sender: Any?) {
        instance.displayMode = enterFullscreen ? .fullscreen : .popOut
        super.showWindow(sender)
        // Land keyboard focus in the guest, so typing works without a click.
        window?.makeFirstResponder(backingView.machineView)
        if enterFullscreen {
            window?.toggleFullScreen(nil)
        }
        updateToolbarItems()
        observeInstance()
    }

    /// Closes the window as an app-initiated dismissal rather than a user close.
    func closeForAppDismissal() {
        close(reason: .appDismissal)
    }

    /// Closes the window as an explicit Pop In.
    func closeForPopIn() {
        close(reason: .popIn)
    }

    /// The single programmatic-close path; idempotent via the `closeReason` guard.
    private func close(reason: CloseReason) {
        guard closeReason == nil else { return }
        lastDisplayID = window?.screen?.displayID
        closeReason = reason
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // A close that arrives without a programmatic reason is the user
        // closing the window (red button / ⌘W).
        if closeReason == nil { closeReason = .userClose }
        if lastDisplayID == nil {
            lastDisplayID = window?.screen?.displayID
        }
        instanceObservation?.cancel()
        instanceObservation = nil
        instance.displayMode = (closeReason == .userClose) ? .hidden : .inline
    }

    func window(
        _ window: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
    ) -> NSApplication.PresentationOptions {
        // RATIONALE: manually toggling `toolbar?.isVisible` on fullscreen
        // enter/exit contaminates the autosaved toolbar configuration (quitting
        // while fullscreen persists "hidden"), so `.autoHideToolbar` does it
        // instead — the toolbar slides in with the menu bar on hover. It requires
        // `.autoHideMenuBar`, which requires `.autoHideDock`.
        [.fullScreen, .autoHideMenuBar, .autoHideDock, .autoHideToolbar]
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        instance.displayMode = .fullscreen
        onUpdateConfiguration { $0.displayPreference = .fullscreen }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard instance.displayMode == .fullscreen else { return }
        instance.displayMode = .popOut
        // Only persist user-initiated exits: during a programmatic close the
        // preference must stay .fullscreen so it restores correctly when the
        // display window is next opened.
        guard closeReason == nil else { return }
        onUpdateConfiguration { $0.displayPreference = .popOut }
    }

    // MARK: - Instance Observation

    private func observeInstance() {
        instanceObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.instance.status
                _ = self.instance.hasLiveVirtualMachine
                _ = self.instance.displayMode
                _ = self.instance.configuration.clipboardSharingEnabled
                _ = self.instance.configuration.displayAutoResizes
                // Everything `displayDropAvailability` reads, so the display
                // registers and unregisters as a drag destination when the guest
                // agent comes and goes, the VM pauses, or the toggle flips.
                _ = self.instance.configuration.dropFilesEnabled
                _ = self.instance.configuration.lastSeenAgentVersion
                _ = self.instance.vsockDropService?.isConnected
                _ = self.instance.vsockControlService?.guestSupportsDropFiles
            },
            apply: { [weak self] in
                guard let self else { return }
                let status = self.instance.status
                if status == .stopped || status == .error || self.instance.isColdPaused {
                    // The VM went away out from under the window.
                    self.closeForAppDismissal()
                } else {
                    self.backingView.update(
                        display: self.instance.session?.displayHandle,
                        isPaused: status == .paused,
                        transitionText: status.transitionLabel,
                        automaticallyReconfiguresDisplay: self.instance.configuration.displayAutoResizes
                    )
                    self.backingView.applyDropRegistration()
                    self.updateToolbarItems()
                }
            }
        )
    }

    // MARK: - Toolbar State

    private func updateToolbarItems() {
        guard let toolbar = window?.toolbar else {
            Self.logger.warning("updateToolbarItems: window or toolbar is nil — toolbar state will be stale")
            return
        }
        toolbarManager.updateToolbarItems(in: toolbar)
    }
}

// MARK: - NSToolbarDelegate

extension VMDisplayWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace] + toolbarManager.defaultItemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.space, .flexibleSpace] + toolbarManager.sharedItemIdentifiers
    }

    func toolbarWillAddItem(_ notification: Notification) {
        // A palette-added item is born with factory-default labels and enablement,
        // and during will-add it is not yet in `toolbar.items` — refresh one
        // runloop turn later so it reflects VM state.
        Task { @MainActor [weak self] in
            self?.updateToolbarItems()
        }
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        toolbarManager.makeToolbarItem(for: itemIdentifier)
    }
}

// MARK: - NSScreen Display ID

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
