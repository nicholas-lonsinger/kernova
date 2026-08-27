import AppKit

/// Step 4 of the creation wizard: review the configuration before creating.
///
/// Read-only rows plus a "start after create" switch, built from a snapshot of
/// the shared ``VMCreationViewModel``. The shell rebuilds this VC each time the
/// review step is entered, so it always reflects current values; the only
/// intra-step changes are the latest-image lookup and a local file's
/// inspection landing.
@MainActor
final class ReviewContentViewController: NSViewController {
    private let creationVM: VMCreationViewModel
    private let startSwitch = NSSwitch()
    /// Rebuilt by ``rebuildSummary()`` when the latest-image lookup lands.
    private let summary = NSStackView()
    /// Redraws the rows once the model's latest-image lookup lands.
    private var latestImageTask: Task<Void, Never>?
    /// Redraws the rows once the model's local-file inspection lands.
    private var localFileInspectionTask: Task<Void, Never>?

    #if DEBUG
    /// Awaited by tests instead of polling for the rows to be redrawn.
    var latestImageTaskForTesting: Task<Void, Never>? { latestImageTask }

    /// Awaited by tests instead of polling for a local file's rows to upgrade.
    var localFileInspectionTaskForTesting: Task<Void, Never>? { localFileInspectionTask }
    #endif
    /// Shows the "more content below" cue while this summary doesn't fit the
    /// sheet; a hint only.
    private var scrollMoreIndicator: ScrollMoreIndicator?

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

        summary.orientation = .vertical
        summary.alignment = .leading
        summary.spacing = Spacing.standard
        summary.translatesAutoresizingMaskIntoConstraints = false
        rebuildSummary()

        let stack = NSStackView(views: [title, subtitle, summary])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.standard
        stack.setCustomSpacing(20, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = makeGroupedFormScrollView(documentView: stack)
        NSLayoutConstraint.activate([
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = scrollView
        scrollMoreIndicator = ScrollMoreIndicator(scrollView: scrollView)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startLatestImageLookup()
        startLocalFileInspectionWatch()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Only this VC's redraw is dropped: the lookup itself belongs to the
        // model, so it still lands for the step shown next.
        latestImageTask?.cancel()
        latestImageTask = nil
        localFileInspectionTask?.cancel()
        localFileInspectionTask = nil
    }

    /// Asks the model what "Download Latest" will fetch, and names it in the rows
    /// when the answer lands.
    ///
    /// A user who reached this step before a slow lookup answered would otherwise
    /// never see those rows. The model's lookup is idempotent, so this joins one
    /// already running rather than starting a second, and retries one that failed
    /// on an earlier step.
    private func startLatestImageLookup() {
        // The rows it fills in belong to this one source; every other source
        // already names its image, and a Linux guest has none.
        guard creationVM.selectedOS == .macOS, creationVM.ipswSource == .downloadLatest else {
            return
        }
        guard latestImageTask == nil, let lookup = creationVM.loadLatestImageDetails() else {
            return
        }
        latestImageTask = Task { [weak self] in
            await lookup.value
            guard let self, !Task.isCancelled else { return }
            self.latestImageTask = nil
            self.rebuildSummary()
        }
    }

    /// Awaits an in-flight local-file inspection, and names it in the rows when
    /// the answer lands.
    ///
    /// A user who reached this step before a slow inspection answered would
    /// otherwise never see the version and size rows.
    private func startLocalFileInspectionWatch() {
        guard creationVM.selectedOS == .macOS, creationVM.ipswSource == .localFile,
            let inspection = creationVM.localFileInspectionTask
        else { return }
        localFileInspectionTask = Task { [weak self] in
            await inspection.value
            guard let self, !Task.isCancelled else { return }
            self.localFileInspectionTask = nil
            self.rebuildSummary()
        }
    }

    /// Fills the summary in from the model, replacing whatever it already held.
    private func rebuildSummary() {
        for view in summary.arrangedSubviews {
            summary.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        addSection(
            "General",
            rows: [
                valueRow("Name", creationVM.vmName),
                valueRow("Operating System", creationVM.selectedOS.displayName),
                valueRow("Boot Mode", creationVM.effectiveBootMode.displayName),
            ], to: summary)

        addSection(
            "Resources",
            rows: [
                valueRow("CPU Cores", "\(creationVM.cpuCount)"),
                valueRow("Memory", "\(creationVM.memoryInGB) GB"),
                valueRow("Disk Size", DataFormatters.formatDiskSize(creationVM.diskSizeInGB)),
            ], to: summary)

        addSection(
            "Network",
            rows: [valueRow("Mode", creationVM.networkEnabled ? "Shared Network" : "None")], to: summary)

        if creationVM.selectedOS == .macOS {
            var rows: [NSView] = []
            switch creationVM.ipswSelection {
            case .downloadLatest:
                rows.append(valueRow("Restore Image", "Download Latest"))
                // Only once the lookup has answered — this source names no
                // particular image on its own.
                if let latest = creationVM.latestImage {
                    rows.append(
                        valueRow("macOS Version", "\(latest.version) (\(latest.build))"))
                    if let sizeBytes = creationVM.latestImageSizeBytes {
                        rows.append(
                            valueRow("Download Size", DataFormatters.formatBytes(sizeBytes)))
                    }
                }
            case .catalogVersion(let entry):
                rows.append(valueRow("Restore Image", "Chosen Version"))
                rows.append(valueRow("macOS Version", "\(entry.version) (\(entry.build))"))
                rows.append(
                    valueRow("Download Size", DataFormatters.formatBytes(entry.sizeBytes)))
            case .customURL(let image):
                rows.append(valueRow("Restore Image", "From URL"))
                rows.append(valueRow("macOS Version", image.versionSummary))
                rows.append(
                    valueRow("Download Size", DataFormatters.formatBytes(image.sizeBytes)))
            case .localFile(let image):
                rows.append(valueRow("Restore Image", "Local File"))
                rows.append(valueRow("File", URL(fileURLWithPath: image.path).lastPathComponent))
                if let inspected = image.inspected {
                    rows.append(
                        valueRow("macOS Version", "\(inspected.version) (\(inspected.build))"))
                    if let sizeBytes = inspected.sizeBytes {
                        rows.append(valueRow("Size", DataFormatters.formatBytes(sizeBytes)))
                    }
                }
            }
            if creationVM.ipswSource.downloadsImage {
                rows.append(
                    valueRow("Save to", wizardAbbreviateWithTilde(creationVM.ipswDownloadPath)))
            }
            addSection("Installation", rows: rows, to: summary)
        }

        if creationVM.selectedOS == .linux {
            var rows: [NSView] = []
            switch creationVM.selectedBootMode {
            case .efi:
                switch creationVM.linuxSelection {
                case .catalogEntry(let entry):
                    rows.append(valueRow("Distribution", entry.distribution))
                    rows.append(valueRow("Version", entry.version))
                    rows.append(
                        valueRow(
                            "Download Size", wizardApproximateSize(entry.approxSizeBytes)))
                    // The folder, not a file: which point release the mirror is
                    // serving — and so what the ISO is called — is only known
                    // once the download resolves it.
                    rows.append(
                        valueRow(
                            "Save to",
                            wizardAbbreviateWithTilde(
                                VMCreationViewModel.downloadsDirectory.path(percentEncoded: false))))
                case .customURL(let image, let sizeBytes):
                    rows.append(valueRow("Installer Image", "From URL"))
                    rows.append(valueRow("File", image.displayName))
                    rows.append(
                        valueRow("Download Size", DataFormatters.formatBytes(sizeBytes)))
                    rows.append(
                        valueRow(
                            "Verification", wizardVerificationSummary(sha256: image.sha256)))
                    // The destination carries a suffix unique to this link, so
                    // it names a file only this pick can ever write.
                    rows.append(
                        valueRow(
                            "Save to",
                            wizardAbbreviateWithTilde(
                                VMCreationViewModel.downloadPath(
                                    forFilename: LinuxImageFilename.destination(for: image.url)))))
                case .localISO(let path, _):
                    rows.append(valueRow("ISO", URL(fileURLWithPath: path).lastPathComponent))
                case nil:
                    break
                }
            case .linuxKernel:
                if let path = creationVM.kernelPath {
                    rows.append(valueRow("Kernel", URL(fileURLWithPath: path).lastPathComponent))
                }
            case .macOS:
                break
            }
            if !rows.isEmpty { addSection("Boot", rows: rows, to: summary) }
        }

        startSwitch.controlSize = .small
        startSwitch.state = creationVM.startAfterCreate ? .on : .off
        startSwitch.target = self
        startSwitch.action = #selector(startToggled)
        if let last = summary.arrangedSubviews.last {
            summary.setCustomSpacing(18, after: last)
        }
        addCard(
            [makeGroupedFormCardRow("Start this VM after creation", control: startSwitch)], to: summary)
    }

    /// Adds a section: a header followed by a grouped card of its rows.
    private func addSection(_ title: String, rows: [NSView], to form: NSStackView) {
        if let last = form.arrangedSubviews.last {
            form.setCustomSpacing(18, after: last)
        }
        let header = makeGroupedFormSectionHeader(title)
        form.addArrangedSubview(header)
        form.setCustomSpacing(6, after: header)
        addCard(rows, to: form)
    }

    private func addCard(_ rows: [NSView], to form: NSStackView) {
        let card = makeGroupedFormCard(rows: rows)
        form.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
    }

    private func valueRow(_ label: String, _ value: String) -> NSView {
        makeGroupedFormCardRow(label, control: makeGroupedFormValueLabel(value), alignment: .firstBaseline)
    }

    @objc private func startToggled() {
        creationVM.startAfterCreate = startSwitch.state == .on
    }
}
