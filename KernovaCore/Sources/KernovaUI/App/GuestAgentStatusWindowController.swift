import Cocoa
import KernovaCore
import KernovaLogging

/// The Guest Agent Status window for one VM: the
/// ``GuestAgentStatusViewController`` the sidebar badge's popover shows, open
/// whether or not the badge is.
///
/// Exists only while the VM's session has a channel to an agent
/// (``VMInstance/agentPresentation``): it cannot be made without one, and it
/// closes when the channel goes. Sized to its content, which it refits on
/// every update.
@MainActor
final class GuestAgentStatusWindowController: NSWindowController, NSWindowDelegate {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "GuestAgentStatusWindowController")

    let instance: VMInstance
    /// Reports the close, while the window is still dispatching it.
    var onWillClose: (() -> Void)?

    private let viewModel: VMLibraryViewModel
    private let statusViewController = GuestAgentStatusViewController()
    private var observation: ObservationLoop?

    /// `nil` when `instance`'s session has no channel to an agent.
    init?(instance: VMInstance, viewModel: VMLibraryViewModel, stage: WindowStage) {
        guard instance.agentPresentation != nil else { return nil }
        self.instance = instance
        self.viewModel = viewModel

        let window = stage.makeWindow(.zero, [.titled, .closable, .miniaturizable])
        super.init(window: window)
        window.delegate = self

        statusViewController.onDiskControl = { [viewModel, instance] in
            Task { @MainActor in await viewModel.toggleGuestAgentDisk(on: instance) }
        }
        statusViewController.onDone = { [weak self] in self?.close() }
        refresh()
        window.contentViewController = statusViewController
        fitContent()
        window.center()
        // Restores the saved frame, whose size the content then overrides.
        window.setFrameAutosaveName(stage.autosave.guestAgentStatusFrame(for: instance.instanceID))
        fitContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GuestAgentStatusWindowController does not support NSCoder")
    }

    // MARK: - Lifecycle

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if observation == nil { observe() }
    }

    func windowWillClose(_ notification: Notification) {
        observation?.cancel()
        observation = nil
        onWillClose?()
    }

    // MARK: - Updates

    private func observe() {
        observation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = instance.agentPresentation
                _ = instance.hasGuestAgentInstallerMounted
                _ = instance.name
                _ = instance.hasLiveEphemeralSession
                _ = GuestAgentDiskControl.model(for: instance, in: viewModel.capabilities)
            },
            apply: { [weak self] in
                guard let self else { return }
                guard refresh() else {
                    Self.logger.log(
                        .notice,
                        "Closing guest agent status window for VM '\(self.instance.name, privacy: .public)': no agent channel"
                    )
                    close()
                    return
                }
                fitContent()
            })
    }

    /// Hands the content and the title what the VM shows now; `false` when
    /// its session has no channel to an agent left to show.
    @discardableResult
    private func refresh() -> Bool {
        guard let presentation = instance.agentPresentation else { return false }
        statusViewController.update(
            presentation: presentation, isInstallerMounted: instance.hasGuestAgentInstallerMounted,
            diskControl: GuestAgentDiskControl.model(for: instance, in: viewModel.capabilities),
            vmName: instance.name,
            // The link dismisses the sidebar's install nudge, which this
            // window is not.
            hasDismissAction: false)
        let name = EphemeralModeCopy.titleName(
            instance.name, ephemeralSessionRunning: instance.hasLiveEphemeralSession)
        window?.title = "\(name) — Guest Agent Status"
        return true
    }

    /// Sizes the window to the content's fitting size, keeping its top edge.
    private func fitContent() {
        guard let window else { return }
        let size = statusViewController.view.fittingSize
        guard window.contentRect(forFrameRect: window.frame).size != size else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }
}
