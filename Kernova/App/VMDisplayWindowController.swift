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
    private let onSaveConfiguration: () -> Void
    private let backingView: VMDisplayBackingView
    private var observingInstance = false

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMDisplayWindowController")

    init(instance: VMInstance, enterFullscreen: Bool, onResume: @escaping () -> Void, onSaveConfiguration: @escaping () -> Void) {
        self.vmID = instance.instanceID
        self.instance = instance
        self.toolbarManager = VMToolbarManager(
            configuration: .init(
                lifecycleID: NSToolbarItem.Identifier("displayLifecycle"),
                saveStateID: NSToolbarItem.Identifier("displaySaveState"),
                clipboardID: nil,
                removableMediaID: NSToolbarItem.Identifier("displayRemovableMedia"),
                displayID: NSToolbarItem.Identifier("displayDisplay"),
                checksPreparing: false,
                gatesDisplayOnCapability: false
            ),
            instanceProvider: { [weak instance] in instance }
        )
        self.enterFullscreen = enterFullscreen
        self.onSaveConfiguration = onSaveConfiguration

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
        window.setFrameAutosaveName("VMDisplay-\(instance.instanceID)")

        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "VMDisplayToolbar-\(instance.instanceID)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
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

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Capture display ID if not already set by the programmatic-close path
        if lastDisplayID == nil {
            lastDisplayID = window?.screen?.displayID
        }
        observingInstance = false
        window?.toolbar?.isVisible = true
        instance.displayMode = .inline
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        instance.displayMode = .fullscreen
        window?.toolbar?.isVisible = false
        if instance.configuration.displayPreference != .fullscreen {
            instance.configuration.displayPreference = .fullscreen
            onSaveConfiguration()
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard instance.displayMode == .fullscreen else { return }
        instance.displayMode = .popOut
        window?.toolbar?.isVisible = true
        // Only update the persisted preference for user-initiated exits.
        // During programmatic close (VM stopped/errored/cold-paused), the
        // preference should remain .fullscreen so it restores correctly
        // when the display window is next opened.
        if !closedProgrammatically && instance.configuration.displayPreference != .popOut {
            instance.configuration.displayPreference = .popOut
            onSaveConfiguration()
        }
    }

    // MARK: - Instance Observation

    /// Observes VM state changes to auto-close the window when the VM stops/errors/saves,
    /// keep toolbar items in sync, and update the backing view's overlay state.
    private func observeInstance() {
        observingInstance = true
        withObservationTracking {
            _ = self.instance.status
            _ = self.instance.virtualMachine
            _ = self.instance.displayMode
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.observingInstance else { return }
                let status = self.instance.status
                if status == .stopped || status == .error || self.instance.isColdPaused {
                    self.lastDisplayID = self.window?.screen?.displayID
                    self.closedProgrammatically = true
                    self.window?.close()
                } else {
                    self.backingView.update(
                        virtualMachine: self.instance.virtualMachine,
                        isPaused: status == .paused,
                        transitionText: status.transitionLabel
                    )
                    self.updateToolbarItems()
                    self.observeInstance()
                }
            }
        }
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
        [.flexibleSpace] + toolbarManager.sharedItemIdentifiers
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
