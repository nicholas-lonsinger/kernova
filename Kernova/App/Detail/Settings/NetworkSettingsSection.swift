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
    private var macAddressGridRow: NSGridRow?

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

        macAddressLabel.font = .monospacedSystemFont(
            ofSize: NSFont.systemFontSize, weight: .regular)
        macAddressLabel.isSelectable = true

        let formGrid = makeFormGrid([
            FormRow("Networking Enabled", control: networkToggle),
            FormRow("MAC Address", control: macAddressLabel),
        ])
        macAddressGridRow = formGrid.grid.row(at: 1)
        section.setBody(formGrid)
        section.setLocked(isReadOnly)
        let isLinux = instance.configuration.guestOS == .linux
        section.setInfoHelp(title: "Network") {
            var paragraphs = [
                "NAT-mode networking. The host assigns the guest a DHCP address on a private subnet."
                    + " Outbound connections work; there is no port forwarding from host to guest —"
                    + " incoming connections require knowing the guest's IP."
            ]
            if isLinux {
                paragraphs.append(
                    "The interface usually appears as enp0s1. If networking doesn't come up, make"
                        + " sure your distro's DHCP client or NetworkManager is running."
                )
            }
            return calloutParagraphs(paragraphs)
        }
    }

    private func apply() {
        networkToggle.state = instance.configuration.networkEnabled ? .on : .off
        if let mac = instance.configuration.macAddress {
            macAddressLabel.stringValue = mac
            macAddressGridRow?.isHidden = false
        } else {
            macAddressGridRow?.isHidden = true
        }
    }

    @objc private func networkToggleChanged(_ sender: NSSwitch) {
        viewModel.updateConfiguration(of: instance) { $0.networkEnabled = sender.state == .on }
    }
}
