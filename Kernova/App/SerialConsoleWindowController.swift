import Cocoa
import os

/// Manages a serial console window for a single VM instance.
///
/// Each VM gets its own window controller. The window hosts a
/// `SerialConsoleContentViewController` and persists its frame position per VM ID.
///
/// The controller observes the VM's status and automatically closes the window when
/// the VM stops or enters an error state.
@MainActor
final class SerialConsoleWindowController: NSWindowController, NSWindowDelegate {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "SerialConsoleWindowController")

    let instance: VMInstance
    private var observingStatus = false

    init(instance: VMInstance) {
        self.instance = instance

        let viewController = SerialConsoleContentViewController(instance: instance)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = viewController
        window.title = "\(instance.name) — Serial Console"
        window.minSize = NSSize(width: 400, height: 200)
        window.setFrameAutosaveName("SerialConsole-\(instance.instanceID.uuidString)")

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
        Self.logger.debug("Serial console window shown for VM '\(self.instance.name, privacy: .public)'")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        observingStatus = false
        Self.logger.debug("Serial console window closing for VM '\(self.instance.name, privacy: .public)'")
    }

    // MARK: - Status Observation

    /// Automatically closes the serial console window when the VM stops or errors out.
    private func observeStatus() {
        observingStatus = true
        withObservationTracking {
            _ = self.instance.status
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.observingStatus else { return }
                let status = self.instance.status
                if status == .stopped || status == .error {
                    Self.logger.notice("Auto-closing serial console for VM '\(self.instance.name, privacy: .public)' (status: \(status.displayName, privacy: .public))")
                    self.window?.close()
                } else {
                    self.observeStatus()
                }
            }
        }
    }
}
