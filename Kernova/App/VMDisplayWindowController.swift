import Cocoa
import os

/// A dedicated window displaying a single VM's screen, either as a resizable
/// pop-out window or in native macOS fullscreen.
///
/// A view under ``VMDisplayPlacementController``: it reports the transitions
/// AppKit performs and writes neither placement field itself.
@MainActor
final class VMDisplayWindowController: NSWindowController, NSWindowDelegate {
    /// What the window observed about itself as it closed, sampled while the
    /// close is still dispatching.
    struct CloseContext {
        /// The display the window was on, which a fullscreen window has already
        /// left by the time its close is handled.
        let lastDisplayID: CGDirectDisplayID?
        let wasKeyWindow: Bool
        let appWasActive: Bool
    }

    let instance: VMInstance
    /// Reports a fullscreen enter/exit AppKit performed.
    var onEnteredFullscreen: (() -> Void)?
    var onExitedFullscreen: (() -> Void)?
    /// Reports the close, while the window is still dispatching it.
    var onWillClose: ((CloseContext) -> Void)?
    /// Asks the owner to dismiss this window: the VM went away out from under
    /// it. Fires on every observation tick while that holds.
    var onRequestDismissal: (() -> Void)?
    private var lastDisplayID: CGDirectDisplayID?
    /// Whether a close is in flight, so the fullscreen transitions AppKit runs
    /// as part of closing the window are not reported as placement changes —
    /// only the view can tell those from a user-initiated enter or exit.
    private var isClosing = false
    private let toolbarManager: VMToolbarManager
    private let enterFullscreen: Bool
    private let backingView: VMDisplayBackingView
    private var instanceObservation: ObservationLoop?

    private static let logger = Logger(subsystem: "app.kernova", category: "VMDisplayWindowController")

    init(
        instance: VMInstance, capabilities: VMCapabilityCatalog, enterFullscreen: Bool,
        onResume: @escaping () -> Void
    ) {
        self.instance = instance
        self.toolbarManager = VMToolbarManager(
            configuration: .init(
                lifecycleID: NSToolbarItem.Identifier("displayLifecycle"),
                saveStateID: NSToolbarItem.Identifier("displaySaveState"),
                takeSnapshotID: NSToolbarItem.Identifier("displayTakeSnapshot"),
                // Targets this window's VM: the nil-target showClipboard action
                // resolves through `AppDelegate.activeInstance`, which prefers the
                // key display window's instance over the sidebar selection.
                clipboardID: NSToolbarItem.Identifier("displayClipboard"),
                popOutID: NSToolbarItem.Identifier("displayPopOut"),
                fullscreenID: NSToolbarItem.Identifier("displayFullscreen"),
                settingsToggleID: nil,
                gatesDisplayOnCapability: false
            ),
            capabilities: capabilities,
            instanceProvider: { [weak instance] in instance }
        )
        self.enterFullscreen = enterFullscreen

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

        updateWindowTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Land keyboard focus in the guest, so typing works without a click.
        window?.makeFirstResponder(backingView.machineView)
        if enterFullscreen {
            window?.toggleFullScreen(nil)
        }
        updateToolbarItems()
        observeInstance()
    }

    /// Closes the window on the owner's behalf; idempotent.
    ///
    /// The display is sampled here because a fullscreen window has left its
    /// screen by the time `windowWillClose(_:)` runs.
    func closeFromOwner() {
        guard !isClosing else { return }
        isClosing = true
        lastDisplayID = window?.screen?.displayID
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        if lastDisplayID == nil {
            lastDisplayID = window?.screen?.displayID
        }
        instanceObservation?.cancel()
        instanceObservation = nil
        onWillClose?(
            CloseContext(
                lastDisplayID: lastDisplayID,
                wasKeyWindow: window?.isKeyWindow ?? false,
                appWasActive: NSApp.isActive))
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
        guard !isClosing else { return }
        onEnteredFullscreen?()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard !isClosing else { return }
        onExitedFullscreen?()
    }

    // MARK: - Instance Observation

    private func observeInstance() {
        instanceObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                // Everything the toolbar's items read, owned by the manager so
                // the read set stays in step with the enablement it feeds —
                // `status` and `hasLiveVirtualMachine`, which the dismissal
                // branch below also reads, are among them.
                self.toolbarManager.trackItemState()
                _ = self.instance.configuration.displayAutoResizes
                // Everything `displayDropAvailability` reads, so the display
                // registers and unregisters as a drag destination when the guest
                // agent comes and goes, the VM pauses, or the toggle flips.
                _ = self.instance.configuration.dropFilesEnabled
                _ = self.instance.configuration.lastSeenAgentVersion
                _ = self.instance.vsockDropService?.isConnected
                _ = self.instance.vsockControlService?.guestSupportsDropFiles
                _ = self.instance.hasLiveEphemeralSession
                _ = self.instance.name
            },
            apply: { [weak self] in
                guard let self else { return }
                let status = self.instance.status
                if status == .stopped || status == .error || self.instance.isColdPaused {
                    // The VM went away out from under the window.
                    self.onRequestDismissal?()
                } else {
                    self.backingView.update(
                        display: self.instance.session?.displayHandle,
                        isPaused: status == .paused,
                        transitionText: status.transitionLabel,
                        automaticallyReconfiguresDisplay: self.instance.configuration.displayAutoResizes
                    )
                    self.backingView.applyDropRegistration()
                    self.updateToolbarItems()
                    self.updateWindowTitle()
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

    private func updateWindowTitle() {
        let name = EphemeralModeCopy.titleName(
            instance.name, ephemeralSessionRunning: instance.hasLiveEphemeralSession)
        window?.title = "\(name) — Display"
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
