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

    /// How a capture confirmed right now would be taken, which the header and
    /// caption describe.
    ///
    /// Not fixed at presentation: the VM can change state while this
    /// window-modal sheet is up, and the mode is stamped at confirm time
    /// (``VMLibraryViewModel/takeSnapshot(_:name:notes:)``) — so the copy has to
    /// follow it or it describes a capture that won't happen.
    private(set) var mode: VMSnapshotCaptureMode

    private let nameField = NSTextField()
    /// Multi-line, so a note can be *written* here and not only edited into
    /// shape afterwards.
    private let notesEditor = NotesEditorView(text: "", placeholder: "Optional")
    private let headerBodyLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var captionLabel = GroupedFormStateNote { [unowned self] in captionText }

    /// The name the sheet would confirm with right now.
    var enteredName: String { nameField.stringValue }
    /// The note the sheet would confirm with right now.
    var enteredNotes: String { notesEditor.text }

    private static let sheetWidth: CGFloat = 520
    private static let padding: CGFloat = 20
    private static let heroPointSize: CGFloat = 48

    init(vmName: String, suggestedName: String, mode: VMSnapshotCaptureMode) {
        self.vmName = vmName
        self.suggestedName = suggestedName
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TakeSnapshotSheetContentViewController does not support NSCoder")
    }

    /// Re-renders the copy for the mode a capture would now be taken in; a
    /// no-op when it hasn't moved.
    func update(mode: VMSnapshotCaptureMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        guard isViewLoaded else { return }
        headerBodyLabel.stringValue = headerBodyText
        captionLabel.refresh()
    }

    override func loadView() {
        captionLabel.refresh()
        let stack = NSStackView(views: [
            makeHeader(), makeFormCard(), captionLabel, makeFooter(),
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

    // MARK: - Copy

    /// What the capture takes, in outcome terms.
    var headerBodyText: String {
        switch mode {
        case .live: "Captures the virtual machine's memory, disks, and settings."
        case .suspended: "Captures the suspended session, disks, and settings."
        case .stopped: "Captures the virtual machine's disks and settings. Reverting returns it powered off."
        }
    }

    /// What the capture does to the running guest, or `nil` when there is none.
    var captionText: String? {
        switch mode {
        case .live: "The virtual machine pauses briefly while its state is written."
        case .suspended: "The virtual machine stays suspended."
        case .stopped: nil
        }
    }

    /// Why a snapshot's listed size overstates the space it takes.
    static let sharedBlocksExplanation =
        "Disks are copied on the same volume, so the copies share their blocks with the virtual machine's "
        + "disks and take almost no extra space until one side changes \u{2014} but the "
        + "snapshot's listed size counts those shared blocks in full."

    // MARK: - Header

    private func makeHeader() -> NSView {
        let icon = NSImageView(
            image: .systemSymbol("clock.arrow.circlepath", accessibilityDescription: ""))
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Self.heroPointSize, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .vertical)

        let title = makeSheetTitle(
            "Take Snapshot of \u{201C}\(vmName)\u{201D}", info: [.body(Self.sharedBlocksExplanation)])

        let body = headerBodyLabel
        body.stringValue = headerBodyText
        body.font = .preferredFont(forTextStyle: .callout)
        body.alignment = .center
        body.maximumNumberOfLines = 0
        body.isSelectable = false

        let stack = NSStackView(views: [icon, title, body])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Spacing.standard
        title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    // MARK: - Form

    private func makeFormCard() -> NSView {
        configureField(nameField, placeholder: "Name")
        nameField.stringValue = suggestedName

        // The Notes box answers Return and Escape itself, so the sheet's default
        // and Cancel buttons never see them while it has focus — it hands both
        // back here instead.
        notesEditor.onCommit = { [weak self] _ in self?.confirmTapped() }
        notesEditor.onCancel = { [weak self] in self?.cancelTapped() }

        return makeGroupedFormCard(rows: [
            GroupedFormFieldRow("Name", control: nameField),
            GroupedFormFieldRow("Notes", control: notesEditor, alignment: .top),
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

        // No ellipsis on the action button itself; the ellipsis lives on the menu
        // item and footer link that open this sheet.
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
            self, didConfirmName: nameField.stringValue, notes: notesEditor.text)
    }
}

// MARK: - NSTextFieldDelegate

extension TakeSnapshotSheetContentViewController: NSTextFieldDelegate {
    /// Return in the Name field confirms, matching the sheet's default button.
    /// The Notes box takes Return for a newline instead.
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        confirmTapped()
        return true
    }
}
