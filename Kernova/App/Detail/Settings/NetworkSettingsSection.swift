import AppKit

/// Network toggle + MAC address display.
@MainActor
final class NetworkSettingsSection: NSObject {
    let section = SettingsSection(title: "Network", lockable: true)

    private let instance: VMInstance
    private let viewModel: VMLibraryViewModel
    private let isReadOnly: Bool

    private let networkToggle = NSSwitch()
    private let macAddressLabel = NSTextField(labelWithString: "")
    private let macAddressRow = NSStackView()

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
            track: { [weak self] in
                guard let self else { return }
                _ = self.instance.configuration.networkEnabled
                _ = self.instance.configuration.macAddress
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
        networkToggle.target = self
        networkToggle.action = #selector(networkToggleChanged(_:))
        networkToggle.isEnabled = !isReadOnly
        let toggleRow = makeLabeledRow("Networking Enabled", control: networkToggle)

        macAddressLabel.font = .monospacedSystemFont(
            ofSize: NSFont.systemFontSize, weight: .regular)
        macAddressLabel.isSelectable = true
        macAddressRow.setViews(
            [
                NSTextField(labelWithString: "MAC Address"),
                settingsSpacer(), macAddressLabel,
            ], in: .leading)
        macAddressRow.orientation = .horizontal
        macAddressRow.spacing = 8

        section.setBody(settingsStackRows([toggleRow, macAddressRow]))
        section.setLocked(isReadOnly)
    }

    private func apply() {
        networkToggle.state = instance.configuration.networkEnabled ? .on : .off
        if let mac = instance.configuration.macAddress {
            macAddressLabel.stringValue = mac
            macAddressRow.isHidden = false
        } else {
            macAddressRow.isHidden = true
        }
    }

    @objc private func networkToggleChanged(_ sender: NSSwitch) {
        viewModel.updateConfiguration(of: instance) { $0.networkEnabled = sender.state == .on }
    }
}
