import AppKit

/// Step 4 of the creation wizard: review the configuration before creating.
///
/// Native macOS grouped cards (System Settings style) of read-only rows plus a
/// "start after create" switch, built from a snapshot of the shared
/// ``VMCreationViewModel``. The shell rebuilds this VC each time the review step
/// is entered, so it always reflects current values; no intra-step observation
/// is needed. Tapping Create is handled by the shell (which reports to its host
/// via the delegate).
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

        addSection(
            "General",
            rows: [
                valueRow("Name", creationVM.vmName),
                valueRow("Operating System", creationVM.selectedOS.displayName),
                valueRow("Boot Mode", creationVM.effectiveBootMode.displayName),
            ], to: form)

        addSection(
            "Resources",
            rows: [
                valueRow("CPU Cores", "\(creationVM.cpuCount)"),
                valueRow("Memory", "\(creationVM.memoryInGB) GB"),
                valueRow("Disk Size", DataFormatters.formatDiskSize(creationVM.diskSizeInGB)),
            ], to: form)

        addSection(
            "Network",
            rows: [valueRow("Networking", creationVM.networkEnabled ? "Enabled" : "Disabled")], to: form)

        if creationVM.selectedOS == .macOS {
            var rows = [
                valueRow(
                    "IPSW Source",
                    creationVM.ipswSource == .downloadLatest ? "Download Latest" : "Local File")
            ]
            if creationVM.ipswSource == .localFile, let path = creationVM.ipswPath {
                rows.append(valueRow("File", URL(fileURLWithPath: path).lastPathComponent))
            }
            if creationVM.ipswSource == .downloadLatest, let path = creationVM.ipswDownloadPath {
                rows.append(valueRow("Save to", wizardAbbreviateWithTilde(path)))
            }
            addSection("Installation", rows: rows, to: form)
        }

        if creationVM.selectedOS == .linux {
            var rows: [NSView] = []
            if let path = creationVM.isoPath {
                rows.append(valueRow("ISO", URL(fileURLWithPath: path).lastPathComponent))
            }
            if let path = creationVM.kernelPath {
                rows.append(valueRow("Kernel", URL(fileURLWithPath: path).lastPathComponent))
            }
            if !rows.isEmpty { addSection("Boot", rows: rows, to: form) }
        }

        startSwitch.controlSize = .small
        startSwitch.state = creationVM.startAfterCreate ? .on : .off
        startSwitch.target = self
        startSwitch.action = #selector(startToggled)
        if let last = form.arrangedSubviews.last {
            form.setCustomSpacing(18, after: last)
        }
        addCard(
            [makeWizardCardRow("Start this VM after creation", control: startSwitch)], to: form)

        return form
    }

    /// Adds a section: a header followed by a grouped card of its rows.
    private func addSection(_ title: String, rows: [NSView], to form: NSStackView) {
        if let last = form.arrangedSubviews.last {
            form.setCustomSpacing(18, after: last)
        }
        let header = makeWizardSectionHeader(title)
        form.addArrangedSubview(header)
        form.setCustomSpacing(6, after: header)
        addCard(rows, to: form)
    }

    private func addCard(_ rows: [NSView], to form: NSStackView) {
        let card = makeWizardCard(rows: rows)
        form.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
    }

    private func valueRow(_ label: String, _ value: String) -> NSView {
        makeWizardCardRow(label, control: makeWizardValueLabel(value), alignment: .firstBaseline)
    }

    @objc private func startToggled() {
        creationVM.startAfterCreate = startSwitch.state == .on
    }
}
