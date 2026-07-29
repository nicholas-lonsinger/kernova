import AppKit
import Foundation

/// Delegate for ``RestoreImageURLSheetContentViewController``.
@MainActor
protocol RestoreImageURLSheetContentViewControllerDelegate: AnyObject {
    /// The user accepted a checked image.
    func restoreImageURLSheet(
        _ vc: RestoreImageURLSheetContentViewController,
        didChoose image: ProbedRestoreImage
    )

    /// The user dismissed without choosing.
    func restoreImageURLSheetDidCancel(
        _ vc: RestoreImageURLSheetContentViewController
    )
}

/// Nested sheet that takes a restore image URL and checks it before anything is
/// downloaded.
///
/// Nothing reaches the install pipeline unchecked: **Use** stays disabled until
/// the probe confirms the URL serves an image carrying the virtual-machine
/// hardware model, which costs about 150 KB rather than the whole file.
@MainActor
final class RestoreImageURLSheetContentViewController: NSViewController {
    weak var delegate: RestoreImageURLSheetContentViewControllerDelegate?

    private let probeService: any RestoreImageProbing
    private let hostVersion: OperatingSystemVersion

    /// The last successful probe, and what **Use** hands to the delegate.
    private(set) var checkedImage: ProbedRestoreImage?

    private let urlField = NSTextField()
    private let checkButton = NSButton()
    private let useButton = NSButton()
    private let resultContainer = NSStackView()

    /// In-flight probe, so a second Check supersedes the first rather than
    /// racing it.
    private var probeTask: Task<Void, Never>?

    #if DEBUG
    /// Awaited by tests instead of polling for the result to land.
    var probeTaskForTesting: Task<Void, Never>? { probeTask }
    #endif

    // MARK: - Layout constants

    private static let sheetWidth: CGFloat = 560
    private static let sheetHeight: CGFloat = 320
    private static let padding: CGFloat = 16

    init(
        probeService: any RestoreImageProbing,
        initialURL: String? = nil,
        hostVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.probeService = probeService
        self.hostVersion = hostVersion
        self.initialURL = initialURL
        super.init(nibName: nil, bundle: nil)
    }

    private let initialURL: String?

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RestoreImageURLSheetContentViewController does not support NSCoder")
    }

    deinit {
        probeTask?.cancel()
    }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()
        let divider1 = makeHorizontalSeparator()
        let body = makeBody()
        let divider2 = makeHorizontalSeparator()
        let footer = makeFooter()

        for subview in [header, divider1, body, divider2, footer] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.sheetWidth),
            container.heightAnchor.constraint(equalToConstant: Self.sheetHeight),

            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            divider1.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider1.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider1.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            body.topAnchor.constraint(equalTo: divider1.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            divider2.topAnchor.constraint(equalTo: body.bottomAnchor),
            divider2.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider2.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            footer.topAnchor.constraint(equalTo: divider2.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
        if let initialURL { urlField.stringValue = initialURL }
        updateControls()
    }

    // MARK: - Header

    private func makeHeader() -> NSView {
        let container = NSView()

        let title = NSTextField(labelWithString: "Add a Restore Image by URL")
        title.font = .preferredFont(forTextStyle: .headline)
        title.isSelectable = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [title, spacer])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Self.padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.padding),
        ])
        return container
    }

    // MARK: - Body

    private func makeBody() -> NSView {
        let container = NSView()

        let label = NSTextField(labelWithString: "Image URL")
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false

        urlField.placeholderString = "Paste a link to an .ipsw restore image"
        urlField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        urlField.lineBreakMode = .byTruncatingHead
        urlField.target = self
        urlField.action = #selector(checkTapped)
        urlField.delegate = self
        urlField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        checkButton.title = "Check"
        checkButton.target = self
        checkButton.action = #selector(checkTapped)
        checkButton.bezelStyle = .rounded
        checkButton.setContentHuggingPriority(.required, for: .horizontal)

        let field = NSStackView(views: [urlField, checkButton])
        field.orientation = .horizontal
        field.alignment = .firstBaseline
        field.spacing = Spacing.standard

        resultContainer.orientation = .vertical
        resultContainer.alignment = .leading
        resultContainer.spacing = Spacing.standard

        let stack = NSStackView(views: [label, field, resultContainer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.small
        stack.setCustomSpacing(Spacing.medium, after: field)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Self.padding),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: container.bottomAnchor, constant: -Self.padding),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return container
    }

    // MARK: - Footer

    private func makeFooter() -> NSView {
        let container = NSView()

        let note = NSTextField(
            labelWithString: "Checked without downloading — about 150 KB read")
        note.font = .preferredFont(forTextStyle: .caption1)
        note.textColor = .tertiaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.isSelectable = false
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"  // Escape

        useButton.title = "Use"
        useButton.target = self
        useButton.action = #selector(useTapped)
        useButton.bezelStyle = .rounded

        let stack = NSStackView(views: [note, spacer, cancel, useButton])
        stack.orientation = .horizontal
        stack.spacing = Spacing.standard
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Self.padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.padding),
        ])
        return container
    }

    // MARK: - Result

    private func setResult(_ views: [NSView]) {
        for view in resultContainer.arrangedSubviews {
            resultContainer.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in views {
            resultContainer.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: resultContainer.widthAnchor).isActive = true
        }
    }

    private func showChecking() {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: "Reading the image directory — about 150 KB…")
        label.font = .preferredFont(forTextStyle: .callout)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [spinner, label, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.small
        setResult([row])
    }

    private func showFailure(_ message: String) {
        setResult([
            makeGroupedFormBanner(
                symbolName: "exclamationmark.triangle.fill",
                tint: .systemYellow,
                message: message
            )
        ])
    }

    private func showSuccess(_ image: ProbedRestoreImage) {
        var rows: [NSView] = [
            makeWizardBadge(
                symbolName: "checkmark.seal.fill",
                text: image.version == nil
                    ? "\(DataFormatters.formatBytes(image.sizeBytes)) · Installs in a virtual machine"
                    : "\(image.versionSummary) · \(DataFormatters.formatBytes(image.sizeBytes)) · Installs in a virtual machine",
                secondaryText: wizardAbbreviateWithTilde(
                    VMCreationViewModel.downloadPath(forFilename: image.suggestedFilename))
            )
        ]

        // The version is read out of the filename, so a "too new" answer is a
        // hint, not a verdict — it warns without blocking Use.
        if image.isSupported(onHost: hostVersion) == false, let version = image.version {
            rows.append(
                makeGroupedFormBanner(
                    symbolName: "exclamationmark.triangle.fill",
                    tint: .systemYellow,
                    message:
                        "The filename says macOS \(version), which is newer than this Mac. If that's right, the install will fail."
                ))
        } else if image.version == nil {
            rows.append(
                makeGroupedFormBanner(
                    symbolName: "info.circle.fill",
                    tint: .systemBlue,
                    message:
                        "The filename doesn't name a macOS version, so the version can't be shown before installing."
                ))
        }
        setResult(rows)
    }

    // MARK: - Controls

    private func updateControls() {
        useButton.isEnabled = checkedImage != nil
        checkButton.isEnabled =
            !urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && probeTask == nil
        // Return commits the check while unverified and the choice once verified,
        // so the default button always does the obvious next thing.
        useButton.keyEquivalent = checkedImage != nil ? "\r" : ""
        checkButton.keyEquivalent = checkedImage == nil ? "\r" : ""
    }

    // MARK: - Actions

    @objc private func checkTapped() {
        let text = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, probeTask == nil else { return }

        guard let url = URL(string: text), url.scheme != nil, url.host() != nil else {
            checkedImage = nil
            showFailure("That isn't a valid URL. Paste the full link, starting with https://")
            updateControls()
            return
        }

        checkedImage = nil
        showChecking()
        probeTask = Task { [weak self, probeService] in
            do {
                let image = try await probeService.probe(url)
                guard let self, !Task.isCancelled else { return }
                self.probeTask = nil
                self.checkedImage = image
                self.showSuccess(image)
                self.updateControls()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.probeTask = nil
                self.checkedImage = nil
                self.showFailure(
                    (error as? RestoreImageProbeError)?.errorDescription
                        ?? error.localizedDescription)
                self.updateControls()
            }
        }
        updateControls()
    }

    @objc private func cancelTapped() {
        probeTask?.cancel()
        probeTask = nil
        delegate?.restoreImageURLSheetDidCancel(self)
    }

    @objc private func useTapped() {
        guard let image = checkedImage else { return }
        delegate?.restoreImageURLSheet(self, didChoose: image)
    }

    // MARK: - Helpers

    private func makeHorizontalSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

// MARK: - NSTextFieldDelegate

extension RestoreImageURLSheetContentViewController: NSTextFieldDelegate {
    /// Editing the URL invalidates the previous verdict and any probe still
    /// running to produce one, so a stale "Use" can't commit an image that
    /// isn't the one in the field.
    func controlTextDidChange(_ obj: Notification) {
        probeTask?.cancel()
        probeTask = nil
        checkedImage = nil
        setResult([])
        updateControls()
    }
}
