import AppKit

/// Step 4 of the creation wizard: review the configuration before creating.
///
/// Read-only summary rows (plus a "start after create" switch), built from a
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

        let stack = NSStackView(views: [title, subtitle, makeSummary()])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = WizardStyle.sectionSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.contentInsets = NSEdgeInsetsZero
        scrollView.documentView = stack

        let bottomPin = stack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor)
        bottomPin.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            bottomPin,
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = scrollView
    }

    private func makeSummary() -> NSView {
        let grid = NSGridView()
        grid.columnSpacing = 12
        grid.rowSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        addWizardSectionHeader(to: grid, "General")
        addRow(to: grid, "Name", creationVM.vmName)
        addRow(to: grid, "Operating System", creationVM.selectedOS.displayName)
        addRow(to: grid, "Boot Mode", creationVM.effectiveBootMode.displayName)

        addWizardSectionHeader(to: grid, "Resources")
        addRow(to: grid, "CPU Cores", "\(creationVM.cpuCount)")
        addRow(to: grid, "Memory", "\(creationVM.memoryInGB) GB")
        addRow(to: grid, "Disk Size", DataFormatters.formatDiskSize(creationVM.diskSizeInGB))

        addWizardSectionHeader(to: grid, "Network")
        addRow(to: grid, "Networking", creationVM.networkEnabled ? "Enabled" : "Disabled")

        if creationVM.selectedOS == .macOS {
            addWizardSectionHeader(to: grid, "Installation")
            addRow(
                to: grid, "IPSW Source",
                creationVM.ipswSource == .downloadLatest ? "Download Latest" : "Local File")
            if creationVM.ipswSource == .localFile, let path = creationVM.ipswPath {
                addRow(to: grid, "File", URL(fileURLWithPath: path).lastPathComponent)
            }
            if creationVM.ipswSource == .downloadLatest, let path = creationVM.ipswDownloadPath {
                addRow(to: grid, "Save to", wizardAbbreviateWithTilde(path))
            }
        }

        if creationVM.selectedOS == .linux {
            addWizardSectionHeader(to: grid, "Boot")
            if let path = creationVM.isoPath {
                addRow(to: grid, "ISO", URL(fileURLWithPath: path).lastPathComponent)
            }
            if let path = creationVM.kernelPath {
                addRow(to: grid, "Kernel", URL(fileURLWithPath: path).lastPathComponent)
            }
        }

        startSwitch.state = creationVM.startAfterCreate ? .on : .off
        startSwitch.target = self
        startSwitch.action = #selector(startToggled)
        let startRow = grid.addRow(with: [
            makeWizardFormLabel("Start this VM after creation"), startSwitch,
        ])
        startRow.topPadding = 8

        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading

        return grid
    }

    private func addRow(to grid: NSGridView, _ label: String, _ value: String) {
        grid.addRow(with: [makeWizardFormLabel(label), makeWizardValueLabel(value)])
    }

    @objc private func startToggled() {
        creationVM.startAfterCreate = startSwitch.state == .on
    }
}
