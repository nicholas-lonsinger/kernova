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
    private static let logger = Logger(subsystem: "app.kernova", category: "ClipboardWindowController")

    let instance: VMInstance
    private var statusObservation: ObservationLoop?

    /// The hosted content controller, retained so blur/close can flush a pending
    /// editor edit before the service grabs the clipboard.
    ///
    /// Named distinctly from the inherited `NSWindowController.contentViewController`,
    /// which is typed `NSViewController?`.
    private let clipboardContentVC: ClipboardContentViewController

    init(instance: VMInstance, viewModel: VMLibraryViewModel) {
        self.instance = instance

        let viewController = ClipboardContentViewController(instance: instance, viewModel: viewModel)
        self.clipboardContentVC = viewController
        // Tall enough for the content area plus the command bar and the
        // agent status bar; the min keeps both bars and a few text lines
        // visible. Autosave name is unchanged so existing saved frames win.
        let initialSize = NSSize(width: 480, height: 320)

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
        window.title = "\(instance.name) — Clipboard"
        window.minSize = NSSize(width: 360, height: 280)
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("Clipboard-\(instance.instanceID.uuidString)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if statusObservation == nil { observeStatus() }
        Self.logger.debug("Clipboard window shown for VM '\(self.instance.name, privacy: .public)'")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Flush any pending edits before the window goes away
        if instance.status == .running || instance.status == .paused {
            clipboardContentVC.flushPendingEdit()
            instance.clipboardService?.grabIfChanged()
        }
        statusObservation?.cancel()
        statusObservation = nil
        Self.logger.debug("Clipboard window closing for VM '\(self.instance.name, privacy: .public)'")
    }

    func windowDidResignKey(_ notification: Notification) {
        clipboardContentVC.flushPendingEdit()
        instance.clipboardService?.grabIfChanged()
    }

    // MARK: - Status Observation

    /// Automatically closes the clipboard window when the VM stops, errors
    /// out, or has clipboard sharing turned off via the live-policy toggle.
    private func observeStatus() {
        statusObservation = observeRecurring(
            track: { [weak self] in
                _ = self?.instance.status
                _ = self?.instance.configuration.clipboardSharingEnabled
            },
            apply: { [weak self] in
                guard let self else { return }
                let status = self.instance.status
                if status == .stopped || status == .error {
                    Self.logger.notice(
                        "Auto-closing clipboard window for VM '\(self.instance.name, privacy: .public)' (status: \(status.displayName, privacy: .public))"
                    )
                    self.window?.close()
                    return
                }
                if !self.instance.configuration.clipboardSharingEnabled {
                    Self.logger.notice(
                        "Auto-closing clipboard window for VM '\(self.instance.name, privacy: .public)' (clipboard sharing disabled by user)"
                    )
                    self.window?.close()
                }
            }
        )
    }
}
