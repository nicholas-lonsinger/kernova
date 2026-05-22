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
        clipboardLinuxHint.translatesAutoresizingMaskIntoConstraints = false
        clipboardLinuxHint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        clipboardLinuxHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let grid = makeFormGrid([
            FormRow("Clipboard Sharing", control: clipboardToggle)
        ])
        let wrapper = NSStackView(views: [grid, clipboardLinuxHint])
        wrapper.orientation = .vertical
        wrapper.alignment = .leading
        wrapper.spacing = 8
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        // RATIONALE: NSStackView `.leading` alignment doesn't stretch
        // arranged subviews to the stack's width. Pin the grid container's
        // and the hint's horizontal edges to the wrapper explicitly:
        // - The grid container needs wrapper-width to center its grid
        //   horizontally (see makeFormGrid).
        // - The hint label needs wrapper-width so wrap-by-word computes
        //   against the section-card width rather than intrinsic content.
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            clipboardLinuxHint.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            clipboardLinuxHint.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])
        section.setBody(wrapper)
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
