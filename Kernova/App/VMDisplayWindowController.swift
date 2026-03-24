import Cocoa
import os
import SwiftUI
import Virtualization

/// Manages a dedicated window displaying a single VM's screen, either as a
/// resizable pop-out window or in native macOS fullscreen.
///
/// On show the inline `VMDisplayView` in the main window is replaced by a placeholder
/// (via `VMInstance.displayMode`), and this controller creates its own
/// `VZVirtualMachineView` bound to the same `VZVirtualMachine`. On close the process
/// reverses so the inline display re-appears.
@MainActor
final class VMDisplayWindowController: NSWindowController, NSWindowDelegate {

    let vmID: UUID
    private(set) var closedProgrammatically = false
    private(set) var lastDisplayID: CGDirectDisplayID?
    let instance: VMInstance
    private let toolbarManager: VMToolbarManager
    private let enterFullscreen: Bool
    private let onSaveConfiguration: () -> Void
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
                displayID: NSToolbarItem.Identifier("displayDisplay"),
                checksPreparing: false,
                gatesDisplayOnCapability: false
            ),
            instanceProvider: { [weak instance] in instance }
        )
        self.enterFullscreen = enterFullscreen
        self.onSaveConfiguration = onSaveConfiguration

        let contentView = DetachedVMView(instance: instance, onResume: onResume)
        let hostingController = NSHostingController(rootView: contentView)
        hostingController.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "\(instance.name) — Display"
        window.collectionBehavior = [.fullScreenPrimary]
        window.restoreFrame(named: "VMDisplay-\(instance.instanceID)")

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

    /// Observes VM state changes to auto-close the window when the VM stops/errors/saves
    /// and to keep toolbar items in sync with current status.
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

// MARK: - Detached VM SwiftUI View

/// SwiftUI view used inside the display window. Shows the VM display when a
/// `VZVirtualMachine` is available (with a pause overlay when live-paused), or a placeholder otherwise.
private struct DetachedVMView: View {
    let instance: VMInstance
    var onResume: () -> Void

    var body: some View {
        if let vm = instance.virtualMachine {
            VMDisplayView(virtualMachine: vm)
                .ignoresSafeArea()
                .vmPauseOverlay(isPaused: instance.status == .paused, onResume: onResume)
                .vmTransitionOverlay(status: instance.status)
        } else if instance.status.isTransitioning || instance.isColdPaused {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(instance.isColdPaused ? "Restoring" : instance.status.displayName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        } else {
            ContentUnavailableView(
                "No Display",
                systemImage: "display",
                description: Text("The virtual machine display is not available.")
            )
        }
    }
}
