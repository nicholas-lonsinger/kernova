import AppKit
import Foundation

/// Delegate for ``LinuxImageURLSheetContentViewController``.
@MainActor
protocol LinuxImageURLSheetContentViewControllerDelegate: AnyObject {
    /// The user accepted a checked image, with the length the check read for it.
    func linuxImageURLSheet(
        _ vc: LinuxImageURLSheetContentViewController,
        didChoose image: CustomLinuxImage,
        sizeBytes: UInt64
    )

    /// The user dismissed without choosing.
    func linuxImageURLSheetDidCancel(
        _ vc: LinuxImageURLSheetContentViewController
    )
}

/// Nested sheet that takes an installer image URL, and the SHA-256 to check the
/// download against, before anything is downloaded.
///
/// **Use** stays disabled until the check passes. What it establishes is that
/// the link is admissible and live and how large the file is — an ISO has no
/// structure to read the way an IPSW's zip directory does. The checksum is
/// optional; without one the download is not verified.
@MainActor
final class LinuxImageURLSheetContentViewController: NSViewController {
    weak var delegate: LinuxImageURLSheetContentViewControllerDelegate?

    private let resolveService: any LinuxImageResolving

    /// The last successful check, and what **Use** hands to the delegate.
    private(set) var checkedImage: CustomLinuxImage?

    /// The length that check read, carried alongside so the wizard can show it.
    private(set) var checkedSizeBytes: UInt64?

    private let urlField = NSTextField()
    private let checksumField = NSTextField()
    private let checkButton = NSButton()
    private let useButton = NSButton()
    private let resultContainer = NSStackView()

    /// In-flight check, so a second Check supersedes the first rather than
    /// racing it.
    private var checkTask: Task<Void, Never>?

    #if DEBUG
    /// Awaited by tests instead of polling for the result to land.
    var checkTaskForTesting: Task<Void, Never>? { checkTask }
    #endif

    // MARK: - Layout constants

    private static let sheetWidth: CGFloat = 560
    private static let sheetHeight: CGFloat = 360
    private static let padding: CGFloat = 16

    init(
        resolveService: any LinuxImageResolving,
        initialURL: String? = nil,
        initialChecksum: String? = nil
    ) {
        self.resolveService = resolveService
        self.initialURL = initialURL
        self.initialChecksum = initialChecksum
        super.init(nibName: nil, bundle: nil)
    }

    private let initialURL: String?
    private let initialChecksum: String?

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LinuxImageURLSheetContentViewController does not support NSCoder")
    }

    deinit {
        checkTask?.cancel()
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
        if let initialChecksum { checksumField.stringValue = initialChecksum }
        updateControls()
    }

    // MARK: - Header

    private func makeHeader() -> NSView {
        let container = NSView()

        let title = NSTextField(labelWithString: "Add an Installer Image by URL")
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

        let urlLabel = makeFieldLabel("Image URL")

        urlField.placeholderString = "Paste a link to an .iso installer image"
        urlField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        urlField.lineBreakMode = .byTruncatingHead
        urlField.target = self
        urlField.action = #selector(checkTapped)
        urlField.delegate = self
        urlField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        checkButton.title = "Check"
        checkButton.target = self
        checkButton.action = #selector(checkTapped)
        checkButton.bezelStyle = .push
        checkButton.setContentHuggingPriority(.required, for: .horizontal)

        let urlRow = NSStackView(views: [urlField, checkButton])
        urlRow.orientation = .horizontal
        urlRow.alignment = .firstBaseline
        urlRow.spacing = Spacing.standard

        let checksumLabel = makeFieldLabel("SHA-256 Checksum")

        checksumField.placeholderString = "Optional"
        checksumField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        checksumField.lineBreakMode = .byTruncatingTail
        checksumField.target = self
        checksumField.action = #selector(checkTapped)
        checksumField.delegate = self
        checksumField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let checksumNote = makeGroupedFormCaption(
            "Without a checksum, the download isn't verified.")

        resultContainer.orientation = .vertical
        resultContainer.alignment = .leading
        resultContainer.spacing = Spacing.standard

        let stack = NSStackView(views: [
            urlLabel, urlRow, checksumLabel, checksumField, checksumNote, resultContainer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.small
        stack.setCustomSpacing(Spacing.medium, after: urlRow)
        stack.setCustomSpacing(Spacing.medium, after: checksumNote)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Self.padding),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: container.bottomAnchor, constant: -Self.padding),
            urlRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            checksumField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            checksumNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return container
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        return label
    }

    // MARK: - Footer

    private func makeFooter() -> NSView {
        let container = NSView()

        let note = NSTextField(labelWithString: "Checked without downloading")
        note.font = .preferredFont(forTextStyle: .caption1)
        note.textColor = .tertiaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.isSelectable = false
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .push
        cancel.keyEquivalent = "\u{1b}"  // Escape

        useButton.title = "Use"
        useButton.target = self
        useButton.action = #selector(useTapped)
        useButton.bezelStyle = .push

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

        let label = NSTextField(labelWithString: "Reading the file's size…")
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

    private func showSuccess(_ image: ResolvedLinuxImage) {
        var rows: [NSView] = [
            makeWizardBadge(
                symbolName: "checkmark.seal.fill",
                text: [
                    image.filename, DataFormatters.formatBytes(image.sizeBytes),
                ].joined(separator: "  ·  "),
                // The destination, which carries a suffix unique to this link so
                // it can never land on a file the user already has.
                secondaryText: wizardAbbreviateWithTilde(
                    VMCreationViewModel.downloadPath(forFilename: image.destinationFilename))
            )
        ]
        if image.sha256 == nil {
            rows.append(
                makeGroupedFormBanner(
                    symbolName: "exclamationmark.triangle.fill",
                    tint: .systemYellow,
                    message:
                        "This download won't be verified. Choose a host you trust."
                ))
        }
        setResult(rows)
    }

    // MARK: - Controls

    private func updateControls() {
        useButton.isEnabled = checkedImage != nil
        checkButton.isEnabled =
            !urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && checkTask == nil
        // Return commits the check while unchecked and the choice once checked,
        // so the default button always does the obvious next thing.
        useButton.keyEquivalent = checkedImage != nil ? "\r" : ""
        checkButton.keyEquivalent = checkedImage == nil ? "\r" : ""
    }

    // MARK: - Actions

    @objc private func checkTapped() {
        guard !urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            checkTask == nil
        else { return }

        // Everything the typed text alone settles — the digest's shape, the
        // scheme the digest's absence demands, the `.iso` the destination is
        // named from — is settled here, so a malformed paste fails at entry
        // rather than after a multi-gigabyte download.
        let image: CustomLinuxImage
        do {
            image = try CustomLinuxImage.make(
                urlText: urlField.stringValue, checksumText: checksumField.stringValue)
        } catch {
            checkedImage = nil
            showFailure(describe(error))
            updateControls()
            return
        }

        checkedImage = nil
        checkedSizeBytes = nil
        showChecking()
        checkTask = Task { [weak self, resolveService] in
            do {
                let resolved = try await resolveService.resolve(image)
                guard let self, !Task.isCancelled else { return }
                self.checkTask = nil
                self.checkedImage = image
                self.checkedSizeBytes = resolved.sizeBytes
                self.showSuccess(resolved)
                self.updateControls()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.checkTask = nil
                self.checkedImage = nil
                self.checkedSizeBytes = nil
                self.showFailure(self.describe(error))
                self.updateControls()
            }
        }
        updateControls()
    }

    private func describe(_ error: any Error) -> String {
        (error as? LinuxImageURLError)?.errorDescription ?? error.localizedDescription
    }

    @objc private func cancelTapped() {
        checkTask?.cancel()
        checkTask = nil
        delegate?.linuxImageURLSheetDidCancel(self)
    }

    @objc private func useTapped() {
        guard let image = checkedImage, let sizeBytes = checkedSizeBytes else { return }
        delegate?.linuxImageURLSheet(self, didChoose: image, sizeBytes: sizeBytes)
    }

    // MARK: - Helpers

    private func makeHorizontalSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

// MARK: - NSTextFieldDelegate

extension LinuxImageURLSheetContentViewController: NSTextFieldDelegate {
    /// Editing either field invalidates the previous verdict and any check
    /// still running to produce one, so a stale "Use" can't commit an image —
    /// or a digest — that isn't the one in the fields.
    func controlTextDidChange(_ obj: Notification) {
        checkTask?.cancel()
        checkTask = nil
        checkedImage = nil
        checkedSizeBytes = nil
        setResult([])
        updateControls()
    }
}
