import AppKit

/// Clipboard-sharing toggle + Linux-guest hint.
@MainActor
final class ClipboardSettingsSection: NSObject {
    let section = SettingsSection(title: "Clipboard")

    private let instance: VMInstance
    private let viewModel: VMLibraryViewModel
    private let isReadOnly: Bool

    private let clipboardToggle = NSSwitch()
    private let clipboardLinuxHint = NSTextField(labelWithString: "")

    private var observation: ObservationLoop?

    init(instance: VMInstance, viewModel: VMLibraryViewModel, isReadOnly: Bool) {
        self.instance = instance
        self.viewModel = viewModel
        self.isReadOnly = isReadOnly
        super.init()
        configure()
    }

    func startObserving() {
        observation = observeRecurring(
            track: { [weak self] in _ = self?.instance.configuration.clipboardSharingEnabled },
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
        clipboardToggle.target = self
        clipboardToggle.action = #selector(clipboardChanged(_:))
        clipboardLinuxHint.font = .preferredFont(forTextStyle: .caption1)
        clipboardLinuxHint.textColor = .systemOrange
        clipboardLinuxHint.stringValue =
            "Takes effect on next start — Linux guests configure SPICE at VM start time."
        clipboardLinuxHint.isHidden = true
        clipboardLinuxHint.maximumNumberOfLines = 0
        clipboardLinuxHint.lineBreakMode = .byWordWrapping
        clipboardLinuxHint.preferredMaxLayoutWidth = 400

        let row = makeLabeledRow("Clipboard Sharing", control: clipboardToggle)
        section.setBody(settingsStackRows([row, clipboardLinuxHint]))
        let isLinux = instance.configuration.guestOS == .linux
        section.setInfoHelp(title: "Clipboard") {
            calloutText(
                isLinux
                    ? "Exchanges clipboard text between host and guest. Requires spice-vdagent"
                        + " installed in the guest via its package manager."
                    : "Exchanges clipboard text between host and guest. Uses the bundled Kernova"
                        + " guest agent — Kernova will offer to install or update it from the"
                        + " clipboard window."
            )
        }
    }

    private func apply() {
        clipboardToggle.state = instance.configuration.clipboardSharingEnabled ? .on : .off
        clipboardLinuxHint.isHidden = !(isReadOnly && instance.configuration.guestOS == .linux)
    }

    @objc private func clipboardChanged(_ sender: NSSwitch) {
        viewModel.updateConfiguration(of: instance) {
            $0.clipboardSharingEnabled = sender.state == .on
        }
    }
}
