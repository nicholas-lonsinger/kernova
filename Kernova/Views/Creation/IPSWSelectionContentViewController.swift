import AppKit
import UniformTypeIdentifiers

/// Step 2 of the creation wizard for macOS guests: choose the IPSW restore image
/// source (download latest vs. local file), show the chosen path, and surface
/// overwrite/resume warnings.
///
/// A native macOS form: a left-aligned heading and a radio-button group for the
/// source. All controls mutate the shared ``VMCreationViewModel`` and then call
/// ``refresh()`` to reconcile the radios, path badge, and banners in place. The
/// shell observes the model separately to keep its Next button in sync.
@MainActor
final class IPSWSelectionContentViewController: NSViewController {
    private let creationVM: VMCreationViewModel

    private var radios: [IPSWSource: NSButton] = [:]

    /// Rebuilt by ``rebuildConditional()`` whenever the source/path/warning state changes.
    private let conditionalContainer = NSStackView()

    init(creationVM: VMCreationViewModel) {
        self.creationVM = creationVM
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("IPSWSelectionContentViewController does not support NSCoder")
    }

    override func loadView() {
        let title = makeWizardTitle("macOS Restore Image")
        let subtitle = makeWizardSubtitle(
            "Choose how to obtain the macOS restore image (IPSW) for installation.")

        let downloadOption = makeSourceRadio(
            for: .downloadLatest,
            symbol: "arrow.down.circle",
            title: "Download Latest",
            description: "Download the latest compatible macOS restore image from Apple."
        )
        let localOption = makeSourceRadio(
            for: .localFile,
            symbol: "folder",
            title: "Choose Local File",
            description: "Select an IPSW file already on your Mac."
        )

        let options = NSStackView(views: [downloadOption, localOption])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = Spacing.large

        conditionalContainer.orientation = .vertical
        conditionalContainer.alignment = .leading
        conditionalContainer.spacing = Spacing.medium

        let stack = NSStackView(views: [title, subtitle, options, conditionalContainer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.standard
        stack.setCustomSpacing(20, after: subtitle)
        stack.setCustomSpacing(20, after: options)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = makeGroupedFormScrollView(documentView: stack)
        NSLayoutConstraint.activate([
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            options.widthAnchor.constraint(equalTo: stack.widthAnchor),
            conditionalContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = scrollView
        refresh()
    }

    // MARK: - Source radios

    private func makeSourceRadio(
        for source: IPSWSource, symbol: String, title: String, description: String
    ) -> NSView {
        let radio = NSButton(
            radioButtonWithTitle: title, target: self, action: #selector(sourceRadioClicked(_:)))
        radios[source] = radio
        return makeWizardRadioOption(radio: radio, iconSymbol: symbol, description: description)
    }

    @objc private func sourceRadioClicked(_ sender: NSButton) {
        guard let source = radios.first(where: { $0.value === sender })?.key else { return }
        switch source {
        case .downloadLatest:
            creationVM.ipswSource = .downloadLatest
            if creationVM.ipswDownloadPath == nil {
                creationVM.ipswDownloadPath = VMCreationViewModel.defaultIPSWDownloadPath
            }
            refresh()
        case .localFile:
            // Selection only commits when the user actually picks a file. Re-sync
            // the radios to the (still-current) model so the just-clicked radio
            // doesn't stay selected if the picker is cancelled, then open it.
            updateRadioSelection()
            selectIPSWFile()
        }
    }

    // MARK: - Refresh

    private func refresh() {
        updateRadioSelection()
        rebuildConditional()
    }

    private func updateRadioSelection() {
        for (source, radio) in radios {
            radio.state = source == creationVM.ipswSource ? .on : .off
        }
    }

    private func rebuildConditional() {
        for view in conditionalContainer.arrangedSubviews {
            conditionalContainer.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        switch creationVM.ipswSource {
        case .downloadLatest:
            guard let path = creationVM.ipswDownloadPath else { return }
            let change = makeWizardLinkButton(
                "Change…", target: self, action: #selector(changeDownloadDestination))
            conditionalContainer.addArrangedSubview(makeWizardPathBadge(path: path, changeButton: change))

            if creationVM.shouldShowOverwriteWarning {
                let useExisting = NSButton(
                    title: "Use Existing File", target: self, action: #selector(useExistingTapped))
                let replace = NSButton(
                    title: "Download & Replace", target: self, action: #selector(confirmOverwriteTapped))
                addFullWidthBanner(
                    makeGroupedFormBanner(
                        symbolName: "exclamationmark.triangle.fill",
                        tint: .systemYellow,
                        message:
                            "A file already exists at this location. It will be replaced when downloading.",
                        trailingButtons: [useExisting, replace]
                    ))
            } else if creationVM.hasResumableDownload {
                addFullWidthBanner(
                    makeGroupedFormBanner(
                        symbolName: "arrow.clockwise.circle.fill",
                        tint: .systemBlue,
                        message:
                            "A previous download was interrupted at this location. It will resume when the install starts."
                    ))
            }
        case .localFile:
            guard let path = creationVM.ipswPath else { return }
            let change = makeWizardLinkButton(
                "Change…", target: self, action: #selector(changeLocalFile))
            conditionalContainer.addArrangedSubview(makeWizardPathBadge(path: path, changeButton: change))
        }
    }

    /// Adds a banner to the conditional container, pinned to the full step width
    /// so it lines up with the source options (the path badge stays content-sized).
    private func addFullWidthBanner(_ banner: NSView) {
        conditionalContainer.addArrangedSubview(banner)
        banner.widthAnchor.constraint(equalTo: conditionalContainer.widthAnchor).isActive = true
    }

    // MARK: - Actions

    @objc private func changeDownloadDestination() {
        selectDownloadDestination()
    }

    @objc private func changeLocalFile() {
        selectIPSWFile()
    }

    @objc private func useExistingTapped() {
        creationVM.useExistingDownloadFile()
        refresh()
    }

    @objc private func confirmOverwriteTapped() {
        creationVM.confirmOverwrite()
        refresh()
    }

    // MARK: - Panels

    private func selectDownloadDestination() {
        let panel = NSSavePanel()
        panel.title = "Choose Download Location"
        if let currentPath = creationVM.ipswDownloadPath {
            let currentURL = URL(fileURLWithPath: currentPath)
            panel.directoryURL = currentURL.deletingLastPathComponent()
            panel.nameFieldStringValue = currentURL.lastPathComponent
        } else {
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            panel.nameFieldStringValue = "RestoreImage.ipsw"
        }
        panel.allowedContentTypes = [.ipsw]

        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.creationVM.ipswDownloadPath = url.path(percentEncoded: false)
            self.refresh()
        }
    }

    private func selectIPSWFile() {
        let panel = NSOpenPanel()
        panel.title = "Select macOS Restore Image"
        panel.allowedContentTypes = [.ipsw]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.creationVM.ipswSource = .localFile
            self.creationVM.ipswPath = url.path(percentEncoded: false)
            self.refresh()
        }
    }
}
