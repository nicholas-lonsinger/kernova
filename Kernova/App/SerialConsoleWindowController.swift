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
    private var statusObservation: ObservationLoop?

    init(instance: VMInstance) {
        self.instance = instance

        let viewController = SerialConsoleContentViewController(instance: instance)
        let initialSize = NSSize(width: 720, height: 480)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = viewController
        // RATIONALE: contentViewController assignment resizes the window to fit
        // the content view's auto layout, which allows near-zero height.
        // Re-establish the intended initial size before setFrameAutosaveName.
        window.setContentSize(initialSize)
        window.title = "\(instance.name) — Serial Console"
        window.minSize = NSSize(width: 400, height: 200)
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("SerialConsole-\(instance.instanceID.uuidString)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if statusObservation == nil { observeStatus() }
        Self.logger.debug("Serial console window shown for VM '\(self.instance.name, privacy: .public)'")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        statusObservation?.cancel()
        statusObservation = nil
        Self.logger.debug("Serial console window closing for VM '\(self.instance.name, privacy: .public)'")
    }

    // MARK: - Status Observation

    /// Automatically closes the serial console window when the VM stops or errors out.
    private func observeStatus() {
        statusObservation = observeRecurring(
            track: { [weak self] in
                _ = self?.instance.status
            },
            apply: { [weak self] in
                guard let self else { return }
                let status = self.instance.status
                if status == .stopped || status == .error {
                    Self.logger.notice("Auto-closing serial console for VM '\(self.instance.name, privacy: .public)' (status: \(status.displayName, privacy: .public))")
                    self.window?.close()
                }
            }
        )
    }
}
