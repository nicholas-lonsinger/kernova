import Cocoa
import os
import Virtualization

/// Manages a dedicated window displaying a single VM's screen, either as a
/// resizable pop-out window or in native macOS fullscreen.
///
/// On show the inline display in the main window is replaced by a placeholder
/// (via `VMInstance.displayMode`), and this controller creates its own
/// `VMDisplayBackingView` (containing a `VZVirtualMachineView`) bound to the same
/// `VZVirtualMachine`. On close the process reverses so the inline display re-appears.
@MainActor
final class VMDisplayWindowController: NSWindowController, NSWindowDelegate {
    let vmID: UUID
    private(set) var closedProgrammatically = false
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
                // resolves through AppDelegate.activeInstance, which prefers the
                // key display window's instance over the sidebar selection.
                clipboardID: NSToolbarItem.Identifier("displayClipboard"),
                displayID: NSToolbarItem.Identifier("displayDisplay"),
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
        backing.update(
            virtualMachine: instance.virtualMachine,
            isPaused: instance.status == .paused,
            transitionText: instance.status.transitionLabel
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

        // RATIONALE: one shared toolbar identifier for every VM's display window
        // (unlike the per-VM frame autosave name above, which is intentionally
        // per-VM) — AppKit synchronizes same-identifier toolbars, so a customized
        // layout applies to all display windows and persists as a single
        // configuration, the way Finder windows share theirs.
        let toolbar = NSToolbar(identifier: "KernovaVMDisplayToolbar")
        toolbar.delegate = self
        // First-run default; the autosaved configuration (restored when the
        // toolbar is attached to the window) overrides this, so all properties
        // must be set before the attach below.
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
        if enterFullscreen {
            window?.toggleFullScreen(nil)
        }
        updateToolbarItems()
        observeInstance()
    }

    /// Closes the window as an app-initiated (programmatic) dismissal rather than a
    /// user close — the single programmatic-close path.
    ///
    /// Marks the close programmatic so `AppDelegate`'s display-window close handler
    /// skips the user-close side effects — reverting `displayPreference` to inline and
    /// restoring the library window. Used both when the agent dismisses the *whole*
    /// GUI (a GUI-origin quit) and when the VM stops/errors/cold-pauses out from under
    /// the window (`observeInstance`). Idempotent via the `closedProgrammatically` guard.
    func closeForAppDismissal() {
        guard !closedProgrammatically else { return }
        lastDisplayID = window?.screen?.displayID
        closedProgrammatically = true
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Capture display ID if not already set by the programmatic-close path
        if lastDisplayID == nil {
            lastDisplayID = window?.screen?.displayID
        }
        instanceObservation?.cancel()
        instanceObservation = nil
        instance.displayMode = .inline
    }

    func window(
        _ window: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
    ) -> NSApplication.PresentationOptions {
        // RATIONALE: .autoHideToolbar replaces the manual toolbar?.isVisible
        // toggling this controller used to do on fullscreen enter/exit, which
        // contaminated the autosaved toolbar configuration (quitting while
        // fullscreen persisted "hidden"). The toolbar now slides in with the menu
        // bar on hover, keeping lifecycle controls reachable in fullscreen.
        // .autoHideToolbar requires .autoHideMenuBar, which requires .autoHideDock
        // (both are the system fullscreen defaults anyway).
        [.fullScreen, .autoHideMenuBar, .autoHideDock, .autoHideToolbar]
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        instance.displayMode = .fullscreen
        onUpdateConfiguration { $0.displayPreference = .fullscreen }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard instance.displayMode == .fullscreen else { return }
        instance.displayMode = .popOut
        // Only update the persisted preference for user-initiated exits.
        // During programmatic close (VM stopped/errored/cold-paused), the
        // preference should remain .fullscreen so it restores correctly
        // when the display window is next opened.
        guard !closedProgrammatically else { return }
        onUpdateConfiguration { $0.displayPreference = .popOut }
    }

    // MARK: - Instance Observation

    /// Observes VM state changes to auto-close the window when the VM stops/errors/saves,
    /// keep toolbar items in sync, and update the backing view's overlay state.
    private func observeInstance() {
        instanceObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.instance.status
                _ = self.instance.virtualMachine
                _ = self.instance.displayMode
                _ = self.instance.configuration.clipboardSharingEnabled
            },
            apply: { [weak self] in
                guard let self else { return }
                let status = self.instance.status
                if status == .stopped || status == .error || self.instance.isColdPaused {
                    // Programmatic close (VM went away out from under the window) — the
                    // same bookkeeping as a GUI-origin dismissal, so share one helper.
                    self.closeForAppDismissal()
                } else {
                    self.backingView.update(
                        virtualMachine: self.instance.virtualMachine,
                        isPaused: status == .paused,
                        transitionText: status.transitionLabel
                    )
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
        [.flexibleSpace] + toolbarManager.sharedItemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.space, .flexibleSpace] + toolbarManager.sharedItemIdentifiers
    }

    func toolbarWillAddItem(_ notification: Notification) {
        // A palette-added item is born with factory-default labels and enablement
        // (autovalidates is false on the shared items), and during will-add it is
        // not yet in toolbar.items — refresh one runloop turn later so it
        // immediately reflects VM state.
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
