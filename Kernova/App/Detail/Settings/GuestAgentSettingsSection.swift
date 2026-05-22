import AppKit

/// macOS-only guest-agent toggles: forward logs + show install reminder.
@MainActor
final class GuestAgentSettingsSection: NSObject {
    let section = SettingsSection(title: "Guest Agent")

    private let instance: VMInstance
    private let viewModel: VMLibraryViewModel

    private let agentLogToggle = NSSwitch()
    private let agentNudgeToggle = NSSwitch()

    private var observation: ObservationLoop?

    init(instance: VMInstance, viewModel: VMLibraryViewModel) {
        self.instance = instance
        self.viewModel = viewModel
        super.init()
        configure()
    }

    func startObserving() {
        observation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.instance.configuration.agentLogForwardingEnabled
                _ = self.instance.configuration.agentInstallNudgeDismissed
            },
            apply: { [weak self] in self?.apply() }
        )
        apply()
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
    }

    // MARK: - Internals

    private func configure() {
        agentLogToggle.target = self
        agentLogToggle.action = #selector(agentLogChanged(_:))
        agentNudgeToggle.target = self
        agentNudgeToggle.action = #selector(agentNudgeChanged(_:))

        let logRow = FormRow(
            "Forward guest logs",
            control: agentLogToggle,
            info: {
                calloutText(
                    "Streams os.Logger records from the macOS guest agent to the host so they"
                        + " appear in Console.app under com.kernova.guest. Off by default; can"
                        + " be toggled while the VM is running."
                )
            }
        )
        let nudgeRow = FormRow(
            "Show install reminder",
            control: agentNudgeToggle,
            info: {
                calloutText(
                    "Surfaces the install icon in the sidebar when the guest agent has not yet"
                        + " connected. Turn off to suppress the nudge for this VM. The more"
                        + " urgent indicators (update available, didn't reconnect, unresponsive)"
                        + " are not affected."
                )
            }
        )
        section.setBody(makeFormGrid([logRow, nudgeRow]))
    }

    private func apply() {
        agentLogToggle.state = instance.configuration.agentLogForwardingEnabled ? .on : .off
        agentNudgeToggle.state = instance.configuration.agentInstallNudgeDismissed ? .off : .on
    }

    @objc private func agentLogChanged(_ sender: NSSwitch) {
        viewModel.updateConfiguration(of: instance) { $0.agentLogForwardingEnabled = sender.state == .on }
    }

    @objc private func agentNudgeChanged(_ sender: NSSwitch) {
        viewModel.updateConfiguration(of: instance) {
            $0.agentInstallNudgeDismissed = !(sender.state == .on)
        }
    }
}
