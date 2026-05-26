import AppKit
import UniformTypeIdentifiers

/// Step 2 of the creation wizard for macOS guests: choose the IPSW restore image
/// source (download latest vs. local file), show the chosen path, and surface
/// overwrite/resume warnings.
///
/// All controls mutate the shared ``VMCreationViewModel`` and then call
/// ``refresh()`` to reconcile the cards, path badge, and banners in place
/// (every state change originates from this VC's own controls, so a synchronous
/// refresh is sufficient and deterministic). The shell observes the model
/// separately to keep its Next button in sync.
@MainActor
final class IPSWSelectionContentViewController: NSViewController {
    private let creationVM: VMCreationViewModel

    private var cards: [IPSWSource: WizardSelectableCardView] = [:]
    private var cardIcons: [IPSWSource: NSImageView] = [:]
    private var cardCheckmarks: [IPSWSource: NSImageView] = [:]

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

        let downloadCard = makeSourceCard(
            for: .downloadLatest,
            symbol: "arrow.down.circle",
            title: "Download Latest",
            description: "Download the latest compatible macOS restore image from Apple."
        )
        let localCard = makeSourceCard(
            for: .localFile,
            symbol: "folder",
            title: "Choose Local File",
            description: "Select an IPSW file already on your Mac."
        )

        let cardStack = NSStackView(views: [downloadCard, localCard])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.distribution = .fill
        cardStack.spacing = 12

        conditionalContainer.orientation = .vertical
        conditionalContainer.alignment = .leading
        conditionalContainer.spacing = 12

        let stack = NSStackView(views: [title, subtitle, cardStack, conditionalContainer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = WizardStyle.sectionSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = makeWizardScrollView(documentView: stack)
        NSLayoutConstraint.activate([
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cardStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            conditionalContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Source cards span the full step width (a leading-aligned stack
            // would otherwise size them to their content).
            downloadCard.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            localCard.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
        ])

        view = scrollView
        refresh()
    }

    // MARK: - Cards

    private func makeSourceCard(
        for source: IPSWSource, symbol: String, title: String, description: String
    ) -> WizardSelectableCardView {
        let icon = NSImageView(image: .systemSymbol(symbol, accessibilityDescription: ""))
        icon.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .title2)
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.isSelectable = false

        let descLabel = NSTextField(wrappingLabelWithString: description)
        descLabel.font = .preferredFont(forTextStyle: .caption1)
        descLabel.textColor = .secondaryLabelColor
        descLabel.maximumNumberOfLines = 0
        descLabel.isSelectable = false

        let textStack = NSStackView(views: [titleLabel, descLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        // The text column expands to fill the space between the icon and the
        // checkmark; the icon/checkmark hug their content. This gives the
        // wrapping description a definite width to wrap at (pinned below),
        // instead of letting it demand an unbounded single-line width that
        // throws off the row's computed height and clips the title.
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let checkmark = NSImageView(
            image: .systemSymbol("checkmark.circle.fill", accessibilityDescription: "Selected"))
        checkmark.contentTintColor = .controlAccentColor
        checkmark.setContentHuggingPriority(.required, for: .horizontal)
        checkmark.setContentCompressionResistancePriority(.required, for: .horizontal)

        let content = NSStackView(views: [icon, textStack, checkmark])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 12

        descLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true

        let card = WizardSelectableCardView(content: content)
        card.onClick = { [weak self] in self?.select(source) }
        cards[source] = card
        cardIcons[source] = icon
        cardCheckmarks[source] = checkmark
        return card
    }

    private func select(_ source: IPSWSource) {
        switch source {
        case .downloadLatest:
            creationVM.ipswSource = .downloadLatest
            if creationVM.ipswDownloadPath == nil {
                creationVM.ipswDownloadPath = VMCreationViewModel.defaultIPSWDownloadPath
            }
            refresh()
        case .localFile:
            // Selection only commits when the user actually picks a file.
            selectIPSWFile()
        }
    }

    // MARK: - Refresh

    private func refresh() {
        updateCardSelection()
        rebuildConditional()
    }

    private func updateCardSelection() {
        for (source, card) in cards {
            let isSelected = source == creationVM.ipswSource
            card.isSelected = isSelected
            cardIcons[source]?.contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
            cardCheckmarks[source]?.isHidden = !isSelected
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
                    makeWizardBanner(
                        symbolName: "exclamationmark.triangle.fill",
                        tint: .systemYellow,
                        message:
                            "A file already exists at this location. It will be replaced when downloading.",
                        trailingButtons: [useExisting, replace]
                    ))
            } else if creationVM.hasResumableDownload {
                addFullWidthBanner(
                    makeWizardBanner(
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
    /// so it lines up with the source cards (the path badge stays content-sized).
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
