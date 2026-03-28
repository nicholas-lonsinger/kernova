import Cocoa
import os

/// Manages a clipboard sharing window for a single VM instance.
///
/// Each VM gets its own window controller. The window hosts a
/// `ClipboardContentViewController` and persists its frame position per VM ID.
///
/// The controller observes the VM's status and automatically closes the window when
/// the VM stops or enters an error state.
@MainActor
final class ClipboardWindowController: NSWindowController, NSWindowDelegate {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "ClipboardWindowController")

    let instance: VMInstance
    private var observingStatus = false

    init(instance: VMInstance) {
        self.instance = instance

        let viewController = ClipboardContentViewController(instance: instance)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = viewController
        window.title = "\(instance.name) — Clipboard"
        window.minSize = NSSize(width: 320, height: 250)
        window.setFrameAutosaveName("Clipboard-\(instance.instanceID.uuidString)")

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if !observingStatus { observeStatus() }
        Self.logger.debug("Clipboard window shown for VM '\(self.instance.name, privacy: .public)'")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Flush any pending edits before the window goes away
        if instance.status == .running || instance.status == .paused {
            instance.clipboardService?.grabIfChanged()
        }
        observingStatus = false
        Self.logger.debug("Clipboard window closing for VM '\(self.instance.name, privacy: .public)'")
    }

    func windowDidResignKey(_ notification: Notification) {
        instance.clipboardService?.grabIfChanged()
    }

    // MARK: - Status Observation

    /// Automatically closes the clipboard window when the VM stops or errors out.
    private func observeStatus() {
        observingStatus = true
        withObservationTracking {
            _ = self.instance.status
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.observingStatus else { return }
                let status = self.instance.status
                if status == .stopped || status == .error {
                    Self.logger.notice("Auto-closing clipboard window for VM '\(self.instance.name, privacy: .public)' (status: \(status.displayName, privacy: .public))")
                    self.window?.close()
                } else {
                    self.observeStatus()
                }
            }
        }
    }
}
