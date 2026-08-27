import AppKit
import UniformTypeIdentifiers
import os

/// Step 2 of the creation wizard for macOS guests: choose where the IPSW restore
/// image comes from, show which image that is and where it lands, and surface
/// overwrite/resume warnings.
///
/// All controls mutate the shared ``VMCreationViewModel`` and then call
/// ``refresh()`` to reconcile the radios, badge, and banners in place. The
/// shell observes the model separately to keep its Next button in sync.
@MainActor
final class IPSWSelectionContentViewController: NSViewController {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "IPSWSelectionContentViewController")

    private let creationVM: VMCreationViewModel

    private var radios: [IPSWSource: NSButton] = [:]

    /// Rebuilt by ``rebuildConditional()`` whenever the source/path/warning state changes.
    private let conditionalContainer = NSStackView()
    /// Hosts the nested version picker.
    private let catalogSheetPresenter = SheetPresenter()

    /// What the last "Use Existing File" attempt turned up, replacing the
    /// overwrite banner while it is set.
    private enum ExistingFileNotice: Equatable {
        case checking
        case mismatch(expected: String, found: InspectedRestoreImage)
        case unusable(message: String)
    }
    private var existingFileNotice: ExistingFileNotice?
    /// The destination ``existingFileNotice`` describes, set with it; a notice
    /// whose path the latest-image lookup has moved away from is stale.
    private var existingFileNoticePath: String?
    /// In-flight inspection, so a second click can't race the first.
    private var adoptTask: Task<Void, Never>?
    /// Redraws the badge once the model's latest-image lookup lands.
    private var latestImageTask: Task<Void, Never>?
    /// Redraws the badge once a panel-picked file's inspection lands.
    private var localFileInspectionWatchTask: Task<Void, Never>?

    #if DEBUG
    /// Awaited by tests instead of polling for the verdict to land.
    var adoptTaskForTesting: Task<Void, Never>? { adoptTask }

    /// Awaited by tests instead of polling for the badge to be redrawn.
    var latestImageTaskForTesting: Task<Void, Never>? { latestImageTask }

    /// Awaited by tests instead of polling for a picked file's badge to upgrade.
    var localFileInspectionTaskForTesting: Task<Void, Never>? { localFileInspectionWatchTask }
    #endif
    /// Shows the "more content below" cue while this step's content overflows the
    /// sheet; a hint only.
    private var scrollMoreIndicator: ScrollMoreIndicator?

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
        let catalogOption = makeSourceRadio(
            for: .catalogVersion,
            symbol: "list.bullet",
            title: "Choose a Version…",
            description: "Browse every macOS release Apple still hosts, including older versions."
        )
        let urlOption = makeSourceRadio(
            for: .customURL,
            symbol: "link",
            title: "Paste an IPSW URL…",
            description: "Install from a restore image at a URL you supply."
        )
        let localOption = makeSourceRadio(
            for: .localFile,
            symbol: "folder",
            title: "Choose Local File…",
            description: "Select an IPSW file already on your Mac."
        )

        let options = NSStackView(views: [downloadOption, catalogOption, urlOption, localOption])
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
        scrollMoreIndicator = ScrollMoreIndicator(scrollView: scrollView)
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startLatestImageLookup()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // The step is swapped out on navigation; a picker left attached to a
        // window that is going away would wedge the presenter as shown.
        catalogSheetPresenter.reset()
        adoptTask?.cancel()
        adoptTask = nil
        // Only this VC's redraw is dropped: the lookup itself belongs to the
        // model, so it still lands for the Review step.
        latestImageTask?.cancel()
        latestImageTask = nil
        localFileInspectionWatchTask?.cancel()
        localFileInspectionWatchTask = nil
    }

    /// Asks the model what "Download Latest" will fetch, and shows it when the
    /// answer lands.
    ///
    /// The model's lookup is idempotent, so re-entering the step joins one
    /// already running rather than starting a second.
    private func startLatestImageLookup() {
        guard latestImageTask == nil, let lookup = creationVM.loadLatestImageDetails() else {
            return
        }
        latestImageTask = Task { [weak self] in
            await lookup.value
            guard let self, !Task.isCancelled else { return }
            self.latestImageTask = nil
            self.rebuildConditional()
        }
    }

    /// Redraws the badge once a just-picked file's inspection lands.
    ///
    /// The inspection itself belongs to the model, so cancelling this watch —
    /// on navigation, or a re-pick starting a new one — drops only this VC's
    /// redraw, never the model's task.
    private func startLocalFileInspectionWatch() {
        guard let inspection = creationVM.localFileInspectionTask else { return }
        localFileInspectionWatchTask?.cancel()
        localFileInspectionWatchTask = Task { [weak self] in
            await inspection.value
            guard let self, !Task.isCancelled else { return }
            self.localFileInspectionWatchTask = nil
            self.rebuildConditional()
        }
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
        // The verdict described the previous source's destination.
        clearExistingFileNotice()
        switch source {
        case .downloadLatest:
            creationVM.selectDownloadLatest()
            refresh()
            // Retries a lookup that failed while another source was selected.
            startLatestImageLookup()
        case .catalogVersion:
            // Same deferred-commit rule as Choose Local File below.
            refresh()
            selectCatalogVersion()
        case .customURL:
            refresh()
            selectPastedURL()
        case .localFile:
            // Selection only commits when the user actually picks a file. Re-render
            // from the (still-current) model so the just-clicked radio doesn't stay
            // selected if the picker is cancelled, then open it.
            refresh()
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

        switch creationVM.ipswSelection {
        case .downloadLatest:
            if let latest = creationVM.latestImage {
                // Nothing here is the user's to change: installing a particular
                // build is what the other sources are for, and the destination
                // is always Downloads, the one location the sandbox's downloads
                // entitlement covers without per-pick grants.
                addImageBadge(
                    parts: [
                        "macOS \(latest.version)", "Build \(latest.build)",
                        creationVM.latestImageSizeBytes.map(DataFormatters.formatBytes),
                    ],
                    path: creationVM.ipswDownloadPath,
                    changeAction: nil
                )
            } else {
                conditionalContainer.addArrangedSubview(
                    makeWizardPathBadge(path: creationVM.ipswDownloadPath))
            }
            // The subject follows the lookup: until it lands the destination is
            // the shared fallback filename, whose occupant may be any image;
            // once it lands, the destination is per-build like a pinned pick's.
            addDownloadBanners(version: creationVM.latestImage?.version)
        case .catalogVersion(let entry):
            addImageBadge(
                parts: [
                    "macOS \(entry.version)", "Build \(entry.build)",
                    DataFormatters.formatBytes(entry.sizeBytes),
                ],
                path: creationVM.ipswDownloadPath,
                changeAction: #selector(changeCatalogVersion)
            )
            addDownloadBanners(version: entry.version)
        case .customURL(let image):
            addImageBadge(
                parts: [image.versionSummary, DataFormatters.formatBytes(image.sizeBytes)],
                path: creationVM.ipswDownloadPath,
                changeAction: #selector(changePastedURL)
            )
            addDownloadBanners(version: image.version)
        case .localFile(let image):
            if let inspected = image.inspected {
                addImageBadge(
                    parts: [
                        "macOS \(inspected.version)", "Build \(inspected.build)",
                        inspected.sizeBytes.map(DataFormatters.formatBytes),
                    ],
                    path: image.path,
                    changeAction: #selector(changeLocalFile)
                )
            } else {
                let change = makeLinkButton(
                    "Change…", target: self, action: #selector(changeLocalFile))
                conditionalContainer.addArrangedSubview(
                    makeWizardPathBadge(path: image.path, changeButton: change))
            }
        }
    }

    /// Adds the one badge a source shows: which image it names, and where that
    /// image lives — the download destination for a download source, or the
    /// picked file's own path for a local one.
    ///
    /// One two-line badge rather than two badges — with four sources listed,
    /// two badges no longer fit the fixed-size sheet without scrolling. Every
    /// source composes its title line from `parts` here, so they read alike;
    /// a part the source doesn't know drops out.
    private func addImageBadge(parts: [String?], path: String, changeAction: Selector?) {
        let change = changeAction.map {
            makeLinkButton("Change…", target: self, action: $0)
        }
        conditionalContainer.addArrangedSubview(
            makeWizardBadge(
                symbolName: "shippingbox.fill",
                text: parts.compactMap { $0 }.joined(separator: "  ·  "),
                secondaryText: wizardAbbreviateWithTilde(path),
                trailingButton: change
            ))
    }

    /// Adds the overwrite or resume banner for whichever download source is
    /// selected, naming `version` when the pick is a specific one.
    private func addDownloadBanners(version: String?) {
        let subject = version.map { "macOS \($0)" }
        // A verdict on the existing file supersedes the plain overwrite
        // warning — it says something more specific about the same file. One
        // for a destination the lookup has since moved away from describes a
        // file that no longer matters, so it drops instead of rendering.
        if let notice = existingFileNotice {
            if existingFileNoticePath == creationVM.ipswDownloadPath {
                addExistingFileNotice(notice)
                return
            }
            clearExistingFileNotice()
        }
        if creationVM.shouldShowOverwriteWarning {
            let useExisting = NSButton(
                title: "Use Existing File", target: self, action: #selector(useExistingTapped))
            let replace = NSButton(
                title: "Download & Replace", target: self, action: #selector(confirmOverwriteTapped))
            addFullWidthBanner(
                makeGroupedFormBanner(
                    symbolName: "exclamationmark.triangle.fill",
                    tint: .systemYellow,
                    message: subject.map { "\($0) is already downloaded. It will be replaced when downloading." }
                        ?? "A file already exists at this location. It will be replaced when downloading.",
                    trailingButtons: [useExisting, replace]
                ))
        } else if creationVM.hasResumableDownload {
            addFullWidthBanner(
                makeGroupedFormBanner(
                    symbolName: "arrow.clockwise.circle.fill",
                    tint: .systemBlue,
                    message: subject.map {
                        "A previous download of \($0) was interrupted. It will resume when the install starts."
                    }
                        ?? "A previous download was interrupted at this location. It will resume when the install starts."
                ))
        }
    }

    /// Renders the outcome of checking the file already at the destination.
    private func addExistingFileNotice(_ notice: ExistingFileNotice) {
        switch notice {
        case .checking:
            addFullWidthBanner(
                makeGroupedFormBanner(
                    symbolName: "magnifyingglass.circle.fill",
                    tint: .systemBlue,
                    message: "Checking the file already at this location…"
                ))
        case .mismatch(let expected, let found):
            let anyway = NSButton(
                title: "Use It Anyway", target: self, action: #selector(useExistingAnywayTapped))
            let replace = NSButton(
                title: "Download & Replace", target: self, action: #selector(confirmOverwriteTapped))
            addFullWidthBanner(
                makeGroupedFormBanner(
                    symbolName: "exclamationmark.triangle.fill",
                    tint: .systemYellow,
                    message:
                        "The file already here is \(found.summary), not build \(expected). Using it installs \(found.summary).",
                    trailingButtons: [anyway, replace]
                ))
        case .unusable(let message):
            let replace = NSButton(
                title: "Download & Replace", target: self, action: #selector(confirmOverwriteTapped))
            addFullWidthBanner(
                makeGroupedFormBanner(
                    symbolName: "exclamationmark.triangle.fill",
                    tint: .systemYellow,
                    message: message,
                    trailingButtons: [replace]
                ))
        }
    }

    /// Adds a banner to the conditional container, pinned to the full step width
    /// so it lines up with the source options (the path badge stays content-sized).
    private func addFullWidthBanner(_ banner: NSView) {
        conditionalContainer.addArrangedSubview(banner)
        banner.widthAnchor.constraint(equalTo: conditionalContainer.widthAnchor).isActive = true
    }

    // MARK: - Actions

    @objc private func changeLocalFile() {
        selectIPSWFile()
    }

    @objc private func changeCatalogVersion() {
        selectCatalogVersion()
    }

    @objc private func changePastedURL() {
        selectPastedURL()
    }

    /// Checks the existing file before adopting it, so a stale or hand-placed
    /// IPSW can't stand in for the version the wizard is showing.
    @objc private func useExistingTapped() {
        guard adoptTask == nil else { return }
        let path = creationVM.ipswDownloadPath
        existingFileNotice = .checking
        existingFileNoticePath = path
        rebuildConditional()
        adoptTask = Task { [weak self] in
            guard let self else { return }
            let verdict = await self.creationVM.adoptExistingDownloadFile(at: path)
            switch verdict {
            case .cancelled:
                // The canceller dropped this task and the notice already, and a
                // later click may own `adoptTask` by now — so touch neither.
                return
            case .adopted:
                self.existingFileNotice = nil
            case .mismatch(let expected, let found):
                self.existingFileNotice = .mismatch(expected: expected, found: found)
            case .unusable(let message):
                self.existingFileNotice = .unusable(message: message)
            }
            self.adoptTask = nil
            self.refresh()
        }
    }

    /// Adopts the file the mismatch banner described, on the user's say-so.
    @objc private func useExistingAnywayTapped() {
        guard case .mismatch(_, let found) = existingFileNotice, let path = existingFileNoticePath
        else {
            Self.logger.fault("Use It Anyway tapped with no mismatch notice")
            assertionFailure("A mismatch banner is showing, so its notice must be set")
            return
        }
        creationVM.useExistingDownloadFile(at: path, inspected: found)
        clearExistingFileNotice()
        refresh()
    }

    @objc private func confirmOverwriteTapped() {
        clearExistingFileNotice()
        creationVM.confirmOverwrite()
        refresh()
    }

    /// Drops any verdict about the existing file, and any inspection still
    /// running to produce one.
    private func clearExistingFileNotice() {
        adoptTask?.cancel()
        adoptTask = nil
        existingFileNotice = nil
        existingFileNoticePath = nil
    }

    // MARK: - Panels

    private func selectIPSWFile() {
        let panel = NSOpenPanel()
        panel.title = "Select macOS Restore Image"
        panel.allowedContentTypes = [.ipsw]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let (path, bookmark) = SecurityScopedBookmark.capture(url)
            self.creationVM.selectLocalFile(path: path, bookmark: bookmark)
            self.refresh()
            self.startLocalFileInspectionWatch()
        }
    }

    /// Opens the nested version picker, preselecting the current pick.
    private func selectCatalogVersion() {
        guard let window = view.window, !catalogSheetPresenter.isShown else { return }
        let sheet = RestoreImageCatalogSheetContentViewController(
            entries: creationVM.catalogService.entries,
            selectedBuild: creationVM.lastCatalogPick?.build,
            generatedAt: creationVM.catalogService.generatedAt
        )
        sheet.delegate = self
        catalogSheetPresenter.show(content: sheet, in: window)
    }

    /// Opens the nested URL sheet, seeded with the current pick.
    private func selectPastedURL() {
        guard let window = view.window, !catalogSheetPresenter.isShown else { return }
        let sheet = RestoreImageURLSheetContentViewController(
            probeService: creationVM.probeService,
            initialURL: creationVM.lastPastedImage?.url.absoluteString
        )
        sheet.delegate = self
        catalogSheetPresenter.show(content: sheet, in: window)
    }
}

// MARK: - RestoreImageURLSheetContentViewControllerDelegate

extension IPSWSelectionContentViewController:
    RestoreImageURLSheetContentViewControllerDelegate
{
    func restoreImageURLSheet(
        _ vc: RestoreImageURLSheetContentViewController,
        didChoose image: ProbedRestoreImage
    ) {
        catalogSheetPresenter.close()
        clearExistingFileNotice()
        creationVM.selectPastedImage(image)
        refresh()
    }

    func restoreImageURLSheetDidCancel(
        _ vc: RestoreImageURLSheetContentViewController
    ) {
        catalogSheetPresenter.close()
    }
}

// MARK: - RestoreImageCatalogSheetContentViewControllerDelegate

extension IPSWSelectionContentViewController:
    RestoreImageCatalogSheetContentViewControllerDelegate
{
    func restoreImageCatalogSheet(
        _ vc: RestoreImageCatalogSheetContentViewController,
        didChoose entry: RestoreImageCatalogEntry
    ) {
        catalogSheetPresenter.close()
        clearExistingFileNotice()
        creationVM.selectCatalogEntry(entry)
        refresh()
    }

    func restoreImageCatalogSheetDidCancel(
        _ vc: RestoreImageCatalogSheetContentViewController
    ) {
        // The model was never touched, so the radios already show the source
        // that was selected before the picker opened.
        catalogSheetPresenter.close()
    }
}
