import AppKit

/// Step 4 of the creation wizard: review the configuration before creating.
///
/// A native macOS aligned form of read-only rows (right-aligned label column,
/// left-aligned values) plus a "start after create" switch, built from a
/// snapshot of the shared ``VMCreationViewModel``. The shell rebuilds this VC
/// each time the review step is entered, so it always reflects current values;
/// no intra-step observation is needed. Tapping Create is handled by the shell
/// (which reports to its host via the delegate).
@MainActor
final class ReviewContentViewController: NSViewController {
    private let creationVM: VMCreationViewModel
    private let startSwitch = NSSwitch()

    init(creationVM: VMCreationViewModel) {
        self.creationVM = creationVM
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ReviewContentViewController does not support NSCoder")
    }

    override func loadView() {
        let title = makeWizardTitle("Review Configuration")
        let subtitle = makeWizardSubtitle(
            "Review your virtual machine settings before creating it.")

        let summary = makeSummary()
        let stack = NSStackView(views: [title, subtitle, summary])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(20, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = makeWizardScrollView(documentView: stack)
        NSLayoutConstraint.activate([
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = scrollView
    }

    private func makeSummary() -> NSView {
        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.translatesAutoresizingMaskIntoConstraints = false

        addSectionHeader("General", to: form)
        addRow("Name", creationVM.vmName, to: form)
        addRow("Operating System", creationVM.selectedOS.displayName, to: form)
        addRow("Boot Mode", creationVM.effectiveBootMode.displayName, to: form)

        addSectionHeader("Resources", to: form)
        addRow("CPU Cores", "\(creationVM.cpuCount)", to: form)
        addRow("Memory", "\(creationVM.memoryInGB) GB", to: form)
        addRow("Disk Size", DataFormatters.formatDiskSize(creationVM.diskSizeInGB), to: form)

        addSectionHeader("Network", to: form)
        addRow("Networking", creationVM.networkEnabled ? "Enabled" : "Disabled", to: form)

        if creationVM.selectedOS == .macOS {
            addSectionHeader("Installation", to: form)
            addRow(
                "IPSW Source",
                creationVM.ipswSource == .downloadLatest ? "Download Latest" : "Local File", to: form)
            if creationVM.ipswSource == .localFile, let path = creationVM.ipswPath {
                addRow("File", URL(fileURLWithPath: path).lastPathComponent, to: form)
            }
            if creationVM.ipswSource == .downloadLatest, let path = creationVM.ipswDownloadPath {
                addRow("Save to", wizardAbbreviateWithTilde(path), to: form)
            }
        }

        if creationVM.selectedOS == .linux {
            addSectionHeader("Boot", to: form)
            if let path = creationVM.isoPath {
                addRow("ISO", URL(fileURLWithPath: path).lastPathComponent, to: form)
            }
            if let path = creationVM.kernelPath {
                addRow("Kernel", URL(fileURLWithPath: path).lastPathComponent, to: form)
            }
        }

        startSwitch.controlSize = .small
        startSwitch.state = creationVM.startAfterCreate ? .on : .off
        startSwitch.target = self
        startSwitch.action = #selector(startToggled)
        if let last = form.arrangedSubviews.last {
            form.setCustomSpacing(18, after: last)
        }
        let startLabel = makeWizardFormLabel("Start this VM after creation")
        let startRow = NSStackView(views: [startSwitch, startLabel])
        startRow.orientation = .horizontal
        startRow.alignment = .centerY
        startRow.spacing = 8
        form.addArrangedSubview(startRow)

        return form
    }

    /// Adds a section header with extra space above it.
    private func addSectionHeader(_ title: String, to form: NSStackView) {
        if let last = form.arrangedSubviews.last {
            form.setCustomSpacing(18, after: last)
        }
        form.addArrangedSubview(makeWizardSectionHeader(title))
    }

    private func addRow(_ label: String, _ value: String, to form: NSStackView) {
        form.addArrangedSubview(makeWizardFormRow(label, control: makeWizardValueLabel(value)))
    }

    @objc private func startToggled() {
        creationVM.startAfterCreate = startSwitch.state == .on
    }
}
