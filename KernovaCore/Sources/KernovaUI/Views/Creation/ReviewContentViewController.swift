import AppKit
import KernovaCommandModel
import KernovaCore

/// Step 4 of the creation wizard: review the configuration before creating.
///
/// Read-only rows plus a "start after create" switch, built from a snapshot of
/// the shared ``VMCreationViewModel``. The shell rebuilds this VC each time the
/// review step is entered, so it always reflects current values.
@MainActor
final class ReviewContentViewController: NSViewController {
    /// What the Account section shows in place of the guest password.
    ///
    /// A fixed run, not one bullet per character: the length is part of the
    /// secret, and a summary row has nothing to do with the password beyond
    /// saying one was set.
    private static let redactedPassword = String(repeating: "\u{2022}", count: 8)

    private let creationVM: VMCreationViewModel
    private let startSwitch = NSSwitch()
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

        let summary = NSStackView()
        summary.orientation = .vertical
        summary.alignment = .leading
        summary.spacing = Spacing.standard
        summary.translatesAutoresizingMaskIntoConstraints = false
        fillSummary(summary)

        let stack = NSStackView(views: [title, summary])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.standard
        stack.setCustomSpacing(20, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = makeGroupedFormScrollView(documentView: stack)
        summary.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        view = scrollView
        scrollMoreIndicator = ScrollMoreIndicator(scrollView: scrollView)
    }

    /// Fills `summary` in from the model.
    private func fillSummary(_ summary: NSStackView) {
        addSection(
            "General",
            rows: [
                valueRow("Name", creationVM.vmName),
                valueRow("Operating system", creationVM.selectedOS.displayName),
                valueRow("Boot mode", creationVM.effectiveBootMode.displayName),
            ], to: summary)

        addSection(
            "Resources",
            rows: [
                valueRow("CPU cores", "\(creationVM.cpuCount)"),
                valueRow("Memory", "\(creationVM.memorySize.gibibytesText) GB"),
                valueRow("Disk size", DataFormatters.formatDiskSize(creationVM.diskSizeInGB)),
            ], to: summary)

        addSection(
            "Network",
            rows: [
                valueRow(
                    "Mode",
                    creationVM.networkEnabled
                        ? NetworkModeChoice.nat.label(attachable: true, interfaces: [], networks: .listed([])).text
                        : NetworkChoiceLabel.noNetwork.text)
            ], to: summary)

        if creationVM.selectedOS == .macOS {
            var rows: [NSView] = []
            switch creationVM.ipswSelection {
            case .downloadLatest:
                rows.append(valueRow("Restore image", "Download Latest"))
                // Only once the lookup has found it — this source names no
                // particular image on its own.
                if case .found(let latest, let sizeBytes) = creationVM.latestImageLookup {
                    rows.append(
                        valueRow("macOS version", "\(latest.version) (\(latest.build))"))
                    if let sizeBytes {
                        rows.append(
                            valueRow("Download size", DataFormatters.formatBytes(sizeBytes)))
                    }
                }
            case .catalogVersion(let entry):
                rows.append(valueRow("Restore image", "Chosen Version"))
                rows.append(valueRow("macOS version", "\(entry.version) (\(entry.build))"))
                rows.append(
                    valueRow("Download size", DataFormatters.formatBytes(entry.sizeBytes)))
            case .customURL(let image):
                rows.append(valueRow("Restore image", "From URL"))
                rows.append(valueRow("macOS version", image.versionSummary))
                rows.append(
                    valueRow("Download size", DataFormatters.formatBytes(image.sizeBytes)))
            case .localFile(let image):
                rows.append(valueRow("Restore image", "Local File"))
                rows.append(valueRow("File", URL(fileURLWithPath: image.path).lastPathComponent))
                if let inspected = image.inspection.usable {
                    rows.append(
                        valueRow("macOS version", "\(inspected.version) (\(inspected.build))"))
                    if let sizeBytes = inspected.sizeBytes {
                        rows.append(valueRow("Size", DataFormatters.formatBytes(sizeBytes)))
                    }
                }
            }
            if let destination = creationVM.ipswDownloadPath {
                rows.append(valueRow("Save to", wizardAbbreviateWithTilde(destination)))
            } else if creationVM.ipswSource == .downloadLatest {
                // The folder, not a file: with no image found, the install
                // names the file from the image it fetches.
                rows.append(
                    valueRow(
                        "Save to",
                        wizardAbbreviateWithTilde(
                            creationVM.downloadsDirectory.path(percentEncoded: false))))
            }
            addSection("Installation", rows: rows, to: summary)

            if let account = creationVM.unattendedSetupIntent {
                addSection(
                    "Account",
                    rows: [
                        valueRow("Full name", account.fullName),
                        valueRow("Account name", account.username),
                        valueRow("Password", Self.redactedPassword),
                        valueRow("Automatic login", account.logsInAutomatically ? "On" : "Off"),
                        valueRow("Remote Login (SSH)", account.enablesRemoteLogin ? "On" : "Off"),
                    ], to: summary)
            }
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
                            "Download size", wizardApproximateSize(entry.approxSizeBytes)))
                    rows.append(
                        valueRow(
                            "Verification",
                            entry.digestSource.title))
                    // The folder, not a file: which point release the mirror is
                    // serving — and so what the ISO is called — is only known
                    // once the download resolves it.
                    rows.append(
                        valueRow(
                            "Save to",
                            wizardAbbreviateWithTilde(
                                creationVM.downloadsDirectory.path(percentEncoded: false))))
                case .customURL(let image, let sizeBytes):
                    rows.append(valueRow("Installer image", "From URL"))
                    rows.append(valueRow("File", image.displayName))
                    rows.append(
                        valueRow("Download size", DataFormatters.formatBytes(sizeBytes)))
                    rows.append(
                        valueRow(
                            "Verification",
                            image.digestSource.pendingCheckTitle))
                    // The destination carries a suffix unique to this link, so
                    // it names a file only this pick can ever write.
                    rows.append(
                        valueRow(
                            "Save to",
                            wizardAbbreviateWithTilde(
                                creationVM.downloadPath(
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
        addGroupedFormFullWidth(card, to: form)
    }

    private func valueRow(_ label: String, _ value: String) -> NSView {
        makeGroupedFormCardRow(label, control: makeGroupedFormValueLabel(value), alignment: .firstBaseline)
    }

    @objc private func startToggled() {
        creationVM.startAfterCreate = startSwitch.state == .on
    }
}
