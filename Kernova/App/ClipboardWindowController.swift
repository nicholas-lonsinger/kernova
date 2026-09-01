import Cocoa
import os

/// Manages a clipboard sharing window for a single VM instance.
///
/// The window hosts a `ClipboardContentViewController`, persists its frame
/// position per VM ID, and closes automatically when the VM stops or enters an
/// error state.
@MainActor
final class ClipboardWindowController: NSWindowController, NSWindowDelegate {
    private static let logger = Logger(subsystem: "app.kernova", category: "ClipboardWindowController")

    let instance: VMInstance
    /// Reports the close, while the window is still dispatching it.
    var onWillClose: (() -> Void)?
    private var statusObservation: ObservationLoop?

    /// The hosted content controller, retained so blur/close can hand off a typed
    /// edit; named distinctly from the inherited `contentViewController`, which
    /// is typed `NSViewController?`.
    private let clipboardContentVC: ClipboardContentViewController

    init(instance: VMInstance, viewModel: VMLibraryViewModel) {
        self.instance = instance

        // Share the VM's host publisher so a manual "Copy to Mac" and the
        // passthrough coordinator write through one instance — the coordinator's
        // echo suppression then recognizes a manual copy's write too.
        let viewController = ClipboardContentViewController(
            instance: instance, viewModel: viewModel, publisher: instance.hostClipboardPublisher)
        self.clipboardContentVC = viewController
        // Tall enough for the buffer card between the command row and the
        // footer; the min keeps the command row, a few lines of the card, the
        // passthrough switch and the agent status line all visible at once.
        let initialSize = NSSize(width: 480, height: 340)

        let window = NSWindow.withStableContentSize(
            initialSize,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            contentViewController: viewController
        )
        window.minSize = NSSize(width: 380, height: 300)
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("Clipboard-\(instance.instanceID.uuidString)")
        updateWindowTitle()
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
        // Carry a user edit to the guest before the window goes away
        if instance.status == .running || instance.status == .paused {
            clipboardContentVC.flushAndAnnounceEdit()
        }
        statusObservation?.cancel()
        statusObservation = nil
        Self.logger.debug("Clipboard window closing for VM '\(self.instance.name, privacy: .public)'")
        onWillClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        clipboardContentVC.flushAndAnnounceEdit()
    }

    // MARK: - Status Observation

    /// Automatically closes the clipboard window when the VM stops, errors
    /// out, or has clipboard sharing turned off via the live-policy toggle.
    private func observeStatus() {
        statusObservation = observeRecurring(
            track: { [weak self] in
                _ = self?.instance.status
                _ = self?.instance.configuration.clipboardSharingEnabled
                _ = self?.instance.name
                _ = self?.instance.hasLiveEphemeralSession
            },
            apply: { [weak self] in
                guard let self else { return }
                self.updateWindowTitle()
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

    private func updateWindowTitle() {
        let name = EphemeralModeCopy.titleName(
            instance.name, ephemeralSessionRunning: instance.hasLiveEphemeralSession)
        window?.title = "\(name) — Clipboard"
    }
}
