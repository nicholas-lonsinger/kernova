import AppKit

/// CPU + memory stepper section in ``VMSettingsViewController``.
@MainActor
final class ResourcesSettingsSection: NSObject {
    let section = SettingsSection(title: "Resources", lockable: true)

    private let instance: VMInstance
    private let viewModel: VMLibraryViewModel
    private let isReadOnly: Bool

    private let cpuStepper = NSStepper()
    private let cpuLabel = NSTextField(labelWithString: "")
    private let memoryStepper = NSStepper()
    private let memoryLabel = NSTextField(labelWithString: "")

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
                _ = self.instance.configuration.cpuCount
                _ = self.instance.configuration.memorySizeInGB
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
        let os = instance.configuration.guestOS

        cpuStepper.minValue = Double(os.minCPUCount)
        cpuStepper.maxValue = Double(os.maxCPUCount)
        cpuStepper.target = self
        cpuStepper.action = #selector(cpuChanged(_:))
        cpuStepper.isEnabled = !isReadOnly

        memoryStepper.minValue = Double(os.minMemoryInGB)
        memoryStepper.maxValue = Double(os.maxMemoryInGB)
        memoryStepper.target = self
        memoryStepper.action = #selector(memoryChanged(_:))
        memoryStepper.isEnabled = !isReadOnly

        cpuLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        memoryLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        let cpuRow = makeLabeledRow(
            "CPU Cores",
            control: settingsHorizontalStack([cpuLabel, cpuStepper], spacing: 6)
        )
        let memRow = makeLabeledRow(
            "Memory",
            control: settingsHorizontalStack([memoryLabel, memoryStepper], spacing: 6)
        )
        section.setBody(settingsStackRows([cpuRow, memRow]))
        section.setLocked(isReadOnly)
    }

    private func apply() {
        cpuStepper.integerValue = instance.configuration.cpuCount
        cpuLabel.stringValue = "\(instance.configuration.cpuCount) cores"
        memoryStepper.integerValue = instance.configuration.memorySizeInGB
        memoryLabel.stringValue = "\(instance.configuration.memorySizeInGB) GB"
    }

    @objc private func cpuChanged(_ sender: NSStepper) {
        viewModel.updateConfiguration(of: instance) { $0.cpuCount = sender.integerValue }
    }

    @objc private func memoryChanged(_ sender: NSStepper) {
        viewModel.updateConfiguration(of: instance) { $0.memorySizeInGB = sender.integerValue }
    }
}
