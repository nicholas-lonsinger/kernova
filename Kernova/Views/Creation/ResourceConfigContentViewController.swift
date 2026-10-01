import AppKit
import KernovaKit

/// Step 3 of the creation wizard: name the VM and allocate resources.
///
/// All controls write the shared ``VMCreationViewModel`` directly. The name field
/// writes on every keystroke so the shell's `canAdvance`/`validationMessage`
/// observation re-evaluates the Next button live. Stepper/field bounds are the
/// Virtualization framework's, the same for every guest.
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

        addCard([GroupedFormFieldRow("Name", control: nameField)], to: form)

        addSectionHeader("Compute", to: form)
        addCard(
            [
                makeGroupedFormCardRow(
                    "CPU cores", control: makeGroupedFormSteppedControl(cpuField, cpuStepper, unit: "")),
                makeGroupedFormCardRow(
                    "Memory", control: makeGroupedFormSteppedControl(memoryField, memoryStepper, unit: "GB")),
            ], to: form)

        addSectionHeader("Storage", to: form)
        addCard([makeGroupedFormCardRow("Disk size", control: diskPopUp)], to: form)
        let caption = GroupedFormStateNote.temporarilyStanding(
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

    private func configureNameField() {
        nameField.stringValue = creationVM.vmName
        nameField.placeholderString = "Name"
        nameField.delegate = self
    }

    private func configureCPU() {
        configureGroupedFormCount(
            field: cpuField, stepper: cpuStepper, bounds: VMResourceLimits.cpuCount,
            value: creationVM.cpuCount, delegate: self, target: self,
            stepperAction: #selector(cpuStepperChanged))
    }

    private func configureMemory() {
        configureGroupedFormMemory(
            field: memoryField, stepper: memoryStepper, bounds: VMResourceLimits.memorySize,
            value: creationVM.memorySize, delegate: self, target: self,
            stepperAction: #selector(memoryStepperChanged))
    }

    private func configureDiskPopUp() {
        diskPopUp.controlSize = .small
        for size in VMGuestOS.allDiskSizes {
            diskPopUp.addItem(withTitle: DataFormatters.formatDiskSize(size))
            diskPopUp.lastItem?.attributedTitle = diskSizeMenuItemTitle(size)
            diskPopUp.lastItem?.tag = size
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
        if let stepped = groupedFormMemoryStep(
            memoryStepper, from: creationVM.memorySize, within: VMResourceLimits.memorySize)
        {
            creationVM.memorySize = stepped
        }
        showMemorySize()
    }

    @objc private func diskChanged() {
        creationVM.diskSizeInGB = diskPopUp.selectedTag()
    }

    @objc private func networkToggled() {
        creationVM.networkEnabled = networkSwitch.state == .on
    }

    /// Clamps a typed CPU/Memory value into the framework's bounds and syncs the
    /// model, the paired stepper, and the field text together.
    ///
    /// Called on end-of-edit, not per keystroke: clamping mid-type would snap the
    /// stepper to the minimum while the field still showed a partial value (e.g.
    /// typing "16" momentarily reads as 1), desyncing the two.
    private func applyCPUFieldEdit() {
        let clamped = VMResourceLimits.cpuCount.clamp(cpuField.integerValue)
        creationVM.cpuCount = clamped
        cpuStepper.integerValue = clamped
        cpuField.integerValue = clamped
    }

    /// The memory field takes decimal gigabytes; text that names no size is
    /// dropped.
    private func applyMemoryFieldEdit() {
        if let typed = VMMemorySize(gibibytesText: memoryField.stringValue) {
            creationVM.memorySize = VMResourceLimits.memorySize.clamp(typed)
        }
        showMemorySize()
    }

    private func showMemorySize() {
        memoryField.stringValue = creationVM.memorySize.gibibytesText
        memoryStepper.doubleValue = creationVM.memorySize.gibibytes
    }
}

// MARK: - NSTextFieldDelegate

extension ResourceConfigContentViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        // Only the name affects `canAdvance`/`validationMessage`, so write it live.
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
