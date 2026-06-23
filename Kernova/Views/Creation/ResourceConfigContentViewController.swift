import AppKit

/// Step 3 of the creation wizard: name the VM and allocate resources.
///
/// Native macOS grouped cards (System Settings style): a heading, then sections
/// of rows inside rounded boxes. All controls write the shared
/// ``VMCreationViewModel`` directly. The name field and the CPU/Memory fields
/// write on every keystroke (via `controlTextDidChange`) so the shell's
/// `canAdvance`/`validationMessage` observation re-evaluates the Next button
/// live. Stepper/field bounds come from the *current* `selectedOS`, and the
/// standing values are clamped into range when the step is built.
@MainActor
final class ResourceConfigContentViewController: NSViewController {
    private let creationVM: VMCreationViewModel

    private let nameField = NSTextField()
    private let cpuField = NSTextField()
    private let cpuStepper = NSStepper()
    private let memoryField = NSTextField()
    private let memoryStepper = NSStepper()
    private let diskPopUp = NSPopUpButton()
    private let networkSwitch = NSSwitch()
    /// Shows the "more content below" cue while this step's content overflows the
    /// sheet; a hint only.
    private var scrollMoreIndicator: ScrollMoreIndicator?

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
        stack.alignment = .leading
        stack.spacing = Spacing.standard
        stack.setCustomSpacing(20, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = makeGroupedFormScrollView(documentView: stack)
        NSLayoutConstraint.activate([
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            form.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = scrollView
        scrollMoreIndicator = ScrollMoreIndicator(scrollView: scrollView)
    }

    // MARK: - Form construction

    private func makeForm() -> NSView {
        configureNameField()
        configureCPU()
        configureMemory()
        configureDiskPopUp()
        configureNetworkSwitch()

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = Spacing.standard
        form.translatesAutoresizingMaskIntoConstraints = false

        addCard([makeGroupedFormCardRow("Name", control: nameField, fillsControl: true)], to: form)

        addSectionHeader("Compute", to: form)
        addCard(
            [
                makeGroupedFormCardRow("CPU Cores", control: steppedControl(cpuField, cpuStepper, unit: "")),
                makeGroupedFormCardRow("Memory", control: steppedControl(memoryField, memoryStepper, unit: "GB")),
            ], to: form)

        addSectionHeader("Storage", to: form)
        addCard([makeGroupedFormCardRow("Disk Size", control: diskPopUp)], to: form)
        let caption = makeGroupedFormCaption(
            "Physical disk usage grows only as data is written (ASIF sparse format).")
        form.addArrangedSubview(caption)
        caption.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true

        addSectionHeader("Network", to: form)
        addCard([makeGroupedFormCardRow("Networking", control: networkSwitch)], to: form)

        return form
    }

    /// Adds a grouped card spanning the form width.
    private func addCard(_ rows: [NSView], to form: NSStackView) {
        let card = makeGroupedFormCard(rows: rows)
        form.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
    }

    /// Adds a section-header label with extra space above it and a tight gap to
    /// the card that follows.
    private func addSectionHeader(_ title: String, to form: NSStackView) {
        if let last = form.arrangedSubviews.last {
            form.setCustomSpacing(18, after: last)
        }
        let header = makeGroupedFormSectionHeader(title)
        form.addArrangedSubview(header)
        form.setCustomSpacing(6, after: header)
    }

    /// Pairs an editable numeric field with its stepper and a trailing unit.
    ///
    /// The unit always occupies a fixed-width slot (empty for unitless values)
    /// so the field and stepper line up in columns across rows regardless of
    /// whether a unit is present.
    private func steppedControl(_ field: NSTextField, _ stepper: NSStepper, unit: String)
        -> NSStackView
    {
        let unitLabel = NSTextField(labelWithString: unit)
        unitLabel.font = Typography.body
        unitLabel.textColor = .secondaryLabelColor
        unitLabel.isSelectable = false
        unitLabel.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let control = NSStackView(views: [field, stepper, unitLabel])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.spacing = Spacing.tight
        return control
    }

    private func configureNameField() {
        nameField.stringValue = creationVM.vmName
        nameField.placeholderString = "Name"
        nameField.delegate = self
    }

    private func configureCPU() {
        let clamped = min(max(creationVM.cpuCount, os.minCPUCount), os.maxCPUCount)
        creationVM.cpuCount = clamped

        cpuField.alignment = .right
        cpuField.delegate = self
        cpuField.integerValue = clamped
        cpuField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        cpuStepper.controlSize = .small
        cpuStepper.minValue = Double(os.minCPUCount)
        cpuStepper.maxValue = Double(os.maxCPUCount)
        cpuStepper.increment = 1
        cpuStepper.valueWraps = false
        cpuStepper.integerValue = clamped
        cpuStepper.target = self
        cpuStepper.action = #selector(cpuStepperChanged)
    }

    private func configureMemory() {
        let clamped = min(max(creationVM.memoryInGB, os.minMemoryInGB), os.maxMemoryInGB)
        creationVM.memoryInGB = clamped

        memoryField.alignment = .right
        memoryField.delegate = self
        memoryField.integerValue = clamped
        memoryField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        memoryStepper.controlSize = .small
        memoryStepper.minValue = Double(os.minMemoryInGB)
        memoryStepper.maxValue = Double(os.maxMemoryInGB)
        memoryStepper.increment = 1
        memoryStepper.valueWraps = false
        memoryStepper.integerValue = clamped
        memoryStepper.target = self
        memoryStepper.action = #selector(memoryStepperChanged)
    }

    private func configureDiskPopUp() {
        diskPopUp.controlSize = .small
        let sizes = os.availableDiskSizes
        for size in sizes {
            diskPopUp.addItem(withTitle: DataFormatters.formatDiskSize(size))
            diskPopUp.lastItem?.attributedTitle = diskSizeMenuItemTitle(size)
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

    // MARK: - Actions

    @objc private func cpuStepperChanged() {
        creationVM.cpuCount = cpuStepper.integerValue
        cpuField.integerValue = cpuStepper.integerValue
    }

    @objc private func memoryStepperChanged() {
        creationVM.memoryInGB = memoryStepper.integerValue
        memoryField.integerValue = memoryStepper.integerValue
    }

    @objc private func diskChanged() {
        creationVM.diskSizeInGB = diskPopUp.selectedTag()
    }

    @objc private func networkToggled() {
        creationVM.networkEnabled = networkSwitch.state == .on
    }

    /// Clamps a typed CPU/Memory value into the OS-allowed range and syncs the
    /// model, the paired stepper, and the field text together.
    ///
    /// Called on end-of-edit (not per keystroke): clamping mid-type would snap
    /// the stepper to the minimum while the field still showed a partial value
    /// (e.g. typing "16" momentarily reads as 1 → clamps to the minimum), which
    /// desyncs the field from the stepper. CPU/Memory don't gate `canAdvance`,
    /// so there's no need to write them live.
    private func applyCPUFieldEdit() {
        let clamped = min(max(cpuField.integerValue, os.minCPUCount), os.maxCPUCount)
        creationVM.cpuCount = clamped
        cpuStepper.integerValue = clamped
        cpuField.integerValue = clamped
    }

    private func applyMemoryFieldEdit() {
        let clamped = min(max(memoryField.integerValue, os.minMemoryInGB), os.maxMemoryInGB)
        creationVM.memoryInGB = clamped
        memoryStepper.integerValue = clamped
        memoryField.integerValue = clamped
    }
}

// MARK: - NSTextFieldDelegate

extension ResourceConfigContentViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        // Only the name affects `canAdvance`/`validationMessage` (which the shell
        // observes), so write it live. CPU/Memory are clamped on end-of-edit to
        // avoid a mid-type stepper/field desync.
        if field === nameField {
            creationVM.vmName = nameField.stringValue
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clamp and reconcile the model, stepper, and field text once editing ends.
        guard let field = obj.object as? NSTextField else { return }
        switch field {
        case cpuField:
            applyCPUFieldEdit()
        case memoryField:
            applyMemoryFieldEdit()
        default:
            break
        }
    }
}
