import AppKit
import KernovaLogging

/// The Check Config Files window's content: a count, a plain-text report of
/// every config file Kernova can't read, and Use Defaults for the ones it can
/// repair.
///
/// Every check reads the files fresh from disk; a later check's result
/// replaces an earlier one's, whichever finishes first.
@MainActor
final class ConfigCheckViewController: NSViewController {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ConfigCheckViewController")

    private let viewModel: VMLibraryViewModel

    private let headerLabel = NSTextField(labelWithString: "")
    private let reportView = NSTextView()
    private let reportScrollView = NSScrollView()
    private let footerLabel = NSTextField(wrappingLabelWithString: "")
    private let showInFinderButton = NSButton()
    private let closeButton = NSButton()
    private let useDefaultsButton = NSButton()

    /// What the window shows, `nil` while no check has finished.
    private(set) var report: ConfigCheckReport?
    /// Counts the checks started, so only the latest one's result lands.
    private var checkGeneration = 0
    private var isWorking = false

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "Check Config Files"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConfigCheckViewController does not support NSCoder")
    }

    // MARK: - View

    override func loadView() {
        headerLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        headerLabel.lineBreakMode = .byWordWrapping
        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        reportView.isEditable = false
        reportView.isSelectable = true
        reportView.isRichText = false
        reportView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        reportView.textContainerInset = NSSize(width: Spacing.tight, height: Spacing.tight)
        reportView.isVerticallyResizable = true
        reportView.isHorizontallyResizable = false
        reportView.autoresizingMask = [.width]
        reportView.textContainer?.widthTracksTextView = true
        reportScrollView.documentView = reportView
        reportScrollView.hasVerticalScroller = true
        reportScrollView.borderType = .bezelBorder
        reportScrollView.translatesAutoresizingMaskIntoConstraints = false

        footerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configure(showInFinderButton, title: "Show in Finder", action: #selector(showInFinder))
        configure(closeButton, title: "Close", action: #selector(closeWindow))
        configure(useDefaultsButton, title: "Use Defaults", action: #selector(useDefaults))
        useDefaultsButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [showInFinderButton, spacer, closeButton, useDefaultsButton])
        buttons.orientation = .horizontal
        buttons.spacing = Spacing.standard

        let content = NSStackView(views: [headerLabel, reportScrollView, footerLabel, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Spacing.relaxed
        content.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(content)
        let pad = Spacing.large
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            headerLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            reportScrollView.widthAnchor.constraint(equalTo: content.widthAnchor),
            reportScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            footerLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        view = root
        apply()
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .push
        button.target = self
        button.action = action
    }

    // MARK: - Checking

    /// Reads every config file again and shows what it found.
    func runCheck() {
        checkGeneration += 1
        let generation = checkGeneration
        isWorking = true
        apply()
        Task { [weak self] in
            guard let self else { return }
            let outcome: Result<[UnreadableConfigFile], any Error>
            do {
                outcome = .success(try await self.viewModel.checkConfigFiles())
            } catch {
                outcome = .failure(error)
            }
            guard generation == self.checkGeneration else { return }
            self.isWorking = false
            switch outcome {
            case .success(let files):
                self.report = ConfigCheckReport(
                    files: files, libraryDirectory: self.viewModel.libraryDirectory)
                self.apply()
            case .failure(let error):
                #log(
                    Self.logger, .error,
                    "The config check couldn't list the VMs folder: \(error.localizedDescription, privacy: .public)"
                )
                self.report = nil
                self.apply(failure: error.localizedDescription)
            }
        }
    }

    /// Lays out what ``report`` holds — or the failure, or that a check is
    /// under way.
    private func apply(failure: String? = nil) {
        guard isViewLoaded else { return }
        if let failure {
            headerLabel.stringValue = "Kernova couldn\u{2019}t check the config files: \(failure)"
        } else if let report {
            headerLabel.stringValue = report.header
        } else {
            headerLabel.stringValue = "Checking config files\u{2026}"
        }
        let files = report?.files ?? []
        reportView.string = report?.body ?? ""
        reportScrollView.isHidden = files.isEmpty
        footerLabel.stringValue = report?.footer ?? ""
        footerLabel.isHidden = report?.footer == nil
        showInFinderButton.isHidden = files.isEmpty
        let offersUseDefaults = (report?.repairableCount ?? 0) > 0
        useDefaultsButton.isHidden = !offersUseDefaults
        useDefaultsButton.isEnabled = !isWorking
        showInFinderButton.isEnabled = !isWorking
        // Return closes the window when there is nothing to repair.
        closeButton.keyEquivalent = offersUseDefaults ? "\u{1b}" : "\r"
    }

    // MARK: - Actions

    @objc private func showInFinder() {
        guard let report else { return }
        NSWorkspace.shared.activateFileViewerSelecting(report.revealedURLs)
    }

    @objc private func closeWindow() {
        view.window?.performClose(nil)
    }

    @objc private func useDefaults() {
        guard let report, report.repairableCount > 0, !isWorking else { return }
        isWorking = true
        apply()
        Task { [weak self] in
            guard let self else { return }
            let failures = await self.viewModel.useDefaults(in: report.files)
            self.isWorking = false
            self.runCheck()
            guard !failures.isEmpty, let window = self.view.window else { return }
            let lines = failures.map {
                "\(report.relativePath(of: $0.file.url)): \($0.reason)"
            }
            presentSheetAlert(
                .acknowledgement(
                    title: "Some Files Weren\u{2019}t Rewritten",
                    message: lines.joined(separator: "\n")),
                in: window)
        }
    }
}
