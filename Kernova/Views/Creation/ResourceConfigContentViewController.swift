import AppKit

/// Step 3 of the creation wizard: name the VM and allocate resources.
///
/// All controls write the shared ``VMCreationViewModel`` directly. The name
/// field writes on every keystroke (via `controlTextDidChange`) so the shell's
/// `canAdvance`/`validationMessage` observation re-evaluates the Next button
/// live. Stepper bounds come from the *current* `selectedOS`, and the standing
/// values are clamped into range when the step is built.
@MainActor
final class ResourceConfigContentViewController: NSViewController {
    private let creationVM: VMCreationViewModel

    private let nameField = NSTextField()
    private let cpuStepper = NSStepper()
    private let cpuValueLabel = NSTextField(labelWithString: "")
    private let memoryStepper = NSStepper()
    private let memoryValueLabel = NSTextField(labelWithString: "")
    private let diskPopUp = NSPopUpButton()
    private let networkSwitch = NSSwitch()

    private var os: VMGuestOS { creationVM.selectedOS }

    init(creationVM: VMCreationViewModel) {
        self.creationVM = creationVM
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ResourceConfigContentViewController does not support NSCoder")
    }

    override func loadView() {
        let title = makeWizardTitle("Configure Resources")
        let subtitle = makeWizardSubtitle(
            "Set the name and resource allocation for your virtual machine.")

        let form = makeForm()
        let stack = NSStackView(views: [title, subtitle, form])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = WizardStyle.sectionSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The form can exceed the fixed sheet height, so host it in a scroll
        // view (the SwiftUI predecessor used a scrollable grouped Form).
        let scrollView = makeWizardScrollView(documentView: stack)
        NSLayoutConstraint.activate([
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            form.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = scrollView
    }

    // MARK: - Form construction

    private func makeForm() -> NSView {
        configureNameField()
        configureCPUStepper()
        configureMemoryStepper()
        configureDiskPopUp()
        configureNetworkSwitch()

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.translatesAutoresizingMaskIntoConstraints = false

        addFullWidth(makeWizardRow(leading: makeWizardFormLabel("Name"), trailing: nameField), to: form)

        addSectionHeader("Compute", to: form)
        addFullWidth(makeWizardRow(leading: cpuValueLabel, trailing: cpuStepper), to: form)
        addFullWidth(makeWizardRow(leading: memoryValueLabel, trailing: memoryStepper), to: form)

        addSectionHeader("Storage", to: form)
        addFullWidth(makeWizardRow(leading: makeWizardFormLabel("Disk Size"), trailing: diskPopUp), to: form)
        let caption = makeWizardCaption(
            "Physical disk usage grows only as data is written (ASIF sparse format).")
        addFullWidth(caption, to: form)

        addSectionHeader("Network", to: form)
        addFullWidth(
            makeWizardRow(leading: makeWizardFormLabel("Networking"), trailing: networkSwitch), to: form)

        return form
    }

    /// Adds an arranged subview to the form and pins its width to the form so
    /// rows span the full step width.
    private func addFullWidth(_ view: NSView, to form: NSStackView) {
        form.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
    }

    /// Adds a section-header label with a little extra space above it.
    private func addSectionHeader(_ title: String, to form: NSStackView) {
        let header = makeWizardSectionHeader(title)
        if let last = form.arrangedSubviews.last {
            form.setCustomSpacing(18, after: last)
        }
        addFullWidth(header, to: form)
    }

    private func configureNameField() {
        nameField.stringValue = creationVM.vmName
        nameField.placeholderString = "Name"
        nameField.delegate = self
        nameField.widthAnchor.constraint(equalToConstant: 240).isActive = true
    }

    private func configureCPUStepper() {
        cpuStepper.controlSize = .small
        cpuStepper.minValue = Double(os.minCPUCount)
        cpuStepper.maxValue = Double(os.maxCPUCount)
        cpuStepper.increment = 1
        cpuStepper.valueWraps = false
        let clamped = min(max(creationVM.cpuCount, os.minCPUCount), os.maxCPUCount)
        creationVM.cpuCount = clamped
        cpuStepper.integerValue = clamped
        cpuStepper.target = self
        cpuStepper.action = #selector(cpuChanged)
        updateCPULabel()
    }

    private func configureMemoryStepper() {
        memoryStepper.controlSize = .small
        memoryStepper.minValue = Double(os.minMemoryInGB)
        memoryStepper.maxValue = Double(os.maxMemoryInGB)
        memoryStepper.increment = 1
        memoryStepper.valueWraps = false
        let clamped = min(max(creationVM.memoryInGB, os.minMemoryInGB), os.maxMemoryInGB)
        creationVM.memoryInGB = clamped
        memoryStepper.integerValue = clamped
        memoryStepper.target = self
        memoryStepper.action = #selector(memoryChanged)
        updateMemoryLabel()
    }

    private func configureDiskPopUp() {
        diskPopUp.controlSize = .small
        let sizes = os.availableDiskSizes
        for size in sizes {
            diskPopUp.addItem(withTitle: DataFormatters.formatDiskSize(size))
            diskPopUp.lastItem?.tag = size
        }
        if !sizes.contains(creationVM.diskSizeInGB), let first = sizes.first {
            creationVM.diskSizeInGB = first
        }
        diskPopUp.selectItem(withTag: creationVM.diskSizeInGB)
        diskPopUp.target = self
        diskPopUp.action = #selector(diskChanged)
    }

    private func configureNetworkSwitch() {
        networkSwitch.controlSize = .small
        networkSwitch.state = creationVM.networkEnabled ? .on : .off
        networkSwitch.target = self
        networkSwitch.action = #selector(networkToggled)
    }

    // MARK: - Label updates

    private func updateCPULabel() {
        cpuValueLabel.stringValue = "CPU Cores: \(creationVM.cpuCount)"
    }

    private func updateMemoryLabel() {
        memoryValueLabel.stringValue = "Memory: \(creationVM.memoryInGB) GB"
    }

    // MARK: - Actions

    @objc private func cpuChanged() {
        creationVM.cpuCount = cpuStepper.integerValue
        updateCPULabel()
    }

    @objc private func memoryChanged() {
        creationVM.memoryInGB = memoryStepper.integerValue
        updateMemoryLabel()
    }

    @objc private func diskChanged() {
        creationVM.diskSizeInGB = diskPopUp.selectedTag()
    }

    @objc private func networkToggled() {
        creationVM.networkEnabled = networkSwitch.state == .on
    }
}

// MARK: - NSTextFieldDelegate

extension ResourceConfigContentViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        // Live write-back so `canAdvance`/`validationMessage` (which the shell
        // observes) re-evaluate on every keystroke.
        creationVM.vmName = nameField.stringValue
    }
}
