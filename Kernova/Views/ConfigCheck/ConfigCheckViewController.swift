import AppKit

/// The Check Config Files window's content: a count, a plain-text report of
/// every config file Kernova can't read, and Use Defaults for the ones it can
/// repair — what its ``ConfigCheckSession`` holds.
@MainActor
final class ConfigCheckViewController: NSViewController {
    let session: ConfigCheckSession
    private var sessionObservation: ObservationLoop?

    private let headerLabel = NSTextField(labelWithString: "")
    private let reportView = NSTextView()
    private let reportScrollView = NSScrollView()
    private let footerLabel = NSTextField(wrappingLabelWithString: "")
    private let showInFinderButton = NSButton()
    private let closeButton = NSButton()
    private let useDefaultsButton = NSButton()

    init(source: any ConfigCheckSource) {
        self.session = ConfigCheckSession(source: source)
        super.init(nibName: nil, bundle: nil)
        title = "Check Config Files"
        session.onRepairFailures = { [weak self] lines in
            guard let window = self?.view.window else { return }
            presentSheetAlert(
                .acknowledgement(
                    title: "Some Files Weren\u{2019}t Rewritten",
                    message: lines.joined(separator: "\n")),
                in: window)
        }
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
        // Use Defaults rewrites files, so it takes a click: Return closes.
        closeButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [showInFinderButton, spacer, closeButton, useDefaultsButton])
        buttons.orientation = .horizontal
        buttons.spacing = Spacing.standard
        // Exactly as tall as its buttons, so the space between gravity areas
        // takes up the slack rather than the row.
        buttons.setHuggingPriority(.defaultHigh, for: .vertical)

        // The button row has the bottom gravity area to itself, so it stays on
        // the bottom edge whichever of the views above are hidden.
        let content = NSStackView()
        content.orientation = .vertical
        content.distribution = .gravityAreas
        content.alignment = .leading
        for view in [headerLabel, reportScrollView, footerLabel] {
            content.addView(view, in: .top)
        }
        content.addView(buttons, in: .bottom)
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
        sessionObservation = observeRecurring(
            track: { [session] in
                _ = session.work
                _ = session.report
                _ = session.failure
            },
            apply: { [weak self] in self?.apply() })
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
        session.check()
    }

    /// Lays out what the session holds: its report — or the failure, or that
    /// a check is under way.
    private func apply() {
        guard isViewLoaded else { return }
        let report = session.report
        if let failure = session.failure {
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
        useDefaultsButton.isHidden = (report?.repairableCount ?? 0) == 0
        let isIdle = session.work == .idle
        useDefaultsButton.isEnabled = isIdle
        showInFinderButton.isEnabled = isIdle
    }

    // MARK: - Actions

    @objc private func showInFinder() {
        guard let report = session.report else { return }
        NSWorkspace.shared.activateFileViewerSelecting(report.revealedURLs)
    }

    @objc private func closeWindow() {
        view.window?.performClose(nil)
    }

    @objc private func useDefaults() {
        session.useDefaults()
    }
}
