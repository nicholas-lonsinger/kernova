import AppKit

/// Delegate for ``TakeSnapshotSheetContentViewController``.
@MainActor
protocol TakeSnapshotSheetContentViewControllerDelegate: AnyObject {
    func takeSnapshotSheetDidCancel(_ vc: TakeSnapshotSheetContentViewController)
    func takeSnapshotSheet(
        _ vc: TakeSnapshotSheetContentViewController, didConfirmName name: String, notes: String)
}

/// Sheet that names a new snapshot before it is taken.
@MainActor
final class TakeSnapshotSheetContentViewController: NSViewController {
    weak var delegate: TakeSnapshotSheetContentViewControllerDelegate?

    private let vmName: String
    private let suggestedName: String

    private let nameField = NSTextField()
    private let notesField = NSTextField()

    /// The name the sheet would confirm with right now.
    var enteredName: String { nameField.stringValue }
    /// The note the sheet would confirm with right now.
    var enteredNotes: String { notesField.stringValue }

    private static let sheetWidth: CGFloat = 520
    private static let padding: CGFloat = 20
    private static let heroPointSize: CGFloat = 48

    init(vmName: String, suggestedName: String) {
        self.vmName = vmName
        self.suggestedName = suggestedName
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TakeSnapshotSheetContentViewController does not support NSCoder")
    }

    override func loadView() {
        let stack = NSStackView(views: [
            makeHeader(), makeFormCard(),
            makeGroupedFormCaption(
                "The VM pauses briefly while its state is written, and its current settings are "
                    + "captured with it. Disks are copied on the same volume, so the copies share "
                    + "their blocks with the VM\u{2019}s disks and take almost no extra space until "
                    + "one side changes \u{2014} but the snapshot\u{2019}s listed size counts those "
                    + "shared blocks in full."),
            makeFooter(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.section
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        let padding = Self.padding
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.sheetWidth),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
        ])
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The suggested name is a starting point, so it arrives selected and
        // typing replaces it.
        view.window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    // MARK: - Header

    private func makeHeader() -> NSView {
        let icon = NSImageView(
            image: .systemSymbol("clock.arrow.circlepath", accessibilityDescription: ""))
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Self.heroPointSize, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .vertical)

        let title = NSTextField(labelWithString: "Take Snapshot of \u{201C}\(vmName)\u{201D}")
        title.font = .preferredFont(forTextStyle: .headline)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        title.isSelectable = false

        let body = NSTextField(
            wrappingLabelWithString:
                "The VM\u{2019}s current memory and disks are captured as a restore point you can "
                + "revert to later.")
        body.font = .preferredFont(forTextStyle: .callout)
        body.alignment = .center
        body.maximumNumberOfLines = 0
        body.isSelectable = false

        let stack = NSStackView(views: [icon, title, body])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Spacing.standard
        for row in [title, body] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    // MARK: - Form

    private func makeFormCard() -> NSView {
        configureField(nameField, placeholder: "Name")
        nameField.stringValue = suggestedName
        configureField(notesField, placeholder: "Optional")

        return makeGroupedFormCard(rows: [
            makeGroupedFormCardRow("Name", control: nameField, fillsControl: true),
            makeGroupedFormCardRow("Notes", control: notesField, fillsControl: true),
        ])
    }

    private func configureField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = Typography.body
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    // MARK: - Footer

    private func makeFooter() -> NSView {
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .push
        cancel.keyEquivalent = "\u{1B}"

        // No ellipsis on the action button itself (project HIG); the ellipsis
        // lives on the menu item and footer link that open this sheet.
        let confirm = NSButton(title: "Take Snapshot", target: self, action: #selector(confirmTapped))
        confirm.bezelStyle = .push
        confirm.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [spacer, cancel, confirm])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.medium
        return row
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        delegate?.takeSnapshotSheetDidCancel(self)
    }

    @objc private func confirmTapped() {
        delegate?.takeSnapshotSheet(
            self, didConfirmName: nameField.stringValue, notes: notesField.stringValue)
    }
}

// MARK: - NSTextFieldDelegate

extension TakeSnapshotSheetContentViewController: NSTextFieldDelegate {
    /// Return in either field confirms, matching the sheet's default button.
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        confirmTapped()
        return true
    }
}
