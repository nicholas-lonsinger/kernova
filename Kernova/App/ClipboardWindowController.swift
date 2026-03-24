import Cocoa
import os
import SwiftUI

/// Manages a clipboard sharing window for a single VM instance.
///
/// Each VM gets its own window controller. The window hosts a `ClipboardContentView`
/// via `NSHostingController` and persists its frame position per VM ID.
///
/// The controller observes the VM's status and automatically closes the window when
/// the VM stops or enters an error state, mirroring `SerialConsoleWindowController` behavior.
@MainActor
final class ClipboardWindowController: NSWindowController, NSWindowDelegate {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "ClipboardWindowController")

    let vmID: UUID
    let instance: VMInstance
    private var observingStatus = false

    init(instance: VMInstance) {
        self.vmID = instance.instanceID
        self.instance = instance

        let contentView = ClipboardContentView(instance: instance)
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "\(instance.name) — Clipboard"
        window.minSize = NSSize(width: 320, height: 280)

        super.init(window: window)
        window.delegate = self

        window.restoreFrame(named: "Clipboard-\(instance.instanceID.uuidString)")
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
        observingStatus = false
        Self.logger.debug("Clipboard window closing for VM '\(self.instance.name, privacy: .public)'")
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
