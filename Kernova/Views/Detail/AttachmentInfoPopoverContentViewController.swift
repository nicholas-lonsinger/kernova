import AppKit

/// Popover content shown by an attachment row's "Get Info" context-menu item
/// (storage disks and removable media alike).
///
/// It is where an attachment's full note is read and written: the Notes box is
/// always offered while the row can be edited, so an attachment with no note
/// yet still has somewhere to gain one.
@MainActor
final class AttachmentInfoPopoverContentViewController: NSViewController {
    private let label: String
    private let fileName: String
    private let fullPath: String
    private let onDiskText: String
    private let allocatedText: String
    private let readOnly: Bool
    private let busText: String
    private let createdText: String
    private let notes: String
    /// Whether the attachment's note can be written right now.
    private let canEdit: Bool
    /// Fires with the edited note when the box commits.
    private let onCommitNotes: (String) -> Void
    /// Fires when Escape reverted the note, so the host can dismiss the popover.
    var onRequestClose: (() -> Void)?
    private var notesEditor: NotesEditorView?

    init(
        label: String,
        fileName: String,
        fullPath: String,
        onDiskText: String,
        allocatedText: String,
        readOnly: Bool,
        busText: String,
        createdText: String,
        notes: String,
        canEdit: Bool,
        onCommitNotes: @escaping (String) -> Void
    ) {
        self.label = label
        self.fileName = fileName
        self.fullPath = fullPath
        self.onDiskText = onDiskText
        self.allocatedText = allocatedText
        self.readOnly = readOnly
        self.busText = busText
        self.createdText = createdText
        self.notes = notes
        self.canEdit = canEdit
        self.onCommitNotes = onCommitNotes
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AttachmentInfoPopoverContentViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CalloutStyle.verticalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(makeCalloutHeadline(label))
        stack.addArrangedSubview(makeFactsGrid())
        stack.addArrangedSubview(keyLabel("Location"))
        stack.addArrangedSubview(makeCalloutCode(fullPath))
        for row in makeNotesRows() { stack.addArrangedSubview(row) }

        container.addSubview(stack)
        let padding = CalloutStyle.padding
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
            container.widthAnchor.constraint(equalToConstant: CalloutStyle.width),
        ])

        view = container
    }

    /// Commits whatever the box holds as the popover goes away — the same
    /// outcome as clicking outside it, which is what dismisses the popover.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        notesEditor?.commitIfChanged()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Re-pin so `NSPopover` resizes its frame to the measured stack height.
        let fittingSize = view.fittingSize
        if preferredContentSize != fittingSize {
            preferredContentSize = fittingSize
        }
    }

    /// The Notes section: an editable box while the row can be written, and
    /// otherwise the note as static text — omitted entirely when there is no
    /// note to read and no way to add one.
    private func makeNotesRows() -> [NSView] {
        guard canEdit else {
            guard !notes.isEmpty else { return [] }
            return [keyLabel("Notes"), makeCalloutBody(notes, color: .labelColor)]
        }
        let editor = NotesEditorView(text: notes)
        editor.onCommit = { [weak self] notes in self?.onCommitNotes(notes) }
        editor.onCancel = { [weak self] in self?.onRequestClose?() }
        editor.widthAnchor.constraint(equalToConstant: CalloutStyle.bodyWidth).isActive = true
        notesEditor = editor
        return [keyLabel("Notes"), editor]
    }

    private func makeFactsGrid() -> NSGridView {
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = Spacing.hairline
        grid.columnSpacing = Spacing.standard
        grid.addRow(with: [keyLabel("File"), valueLabel(fileName)])
        grid.addRow(with: [keyLabel("On disk"), valueLabel(onDiskText)])
        grid.addRow(with: [keyLabel("Allocated"), valueLabel(allocatedText)])
        grid.addRow(with: [keyLabel("Read only"), valueLabel(readOnly ? "Yes" : "No")])
        grid.addRow(with: [keyLabel("Bus"), valueLabel(busText)])
        grid.addRow(with: [keyLabel("Created"), valueLabel(createdText)])
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading
        return grid
    }

    private func keyLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = CalloutStyle.bodyFont
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private func valueLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = CalloutStyle.bodyFont
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.isSelectable = true
        return label
    }
}
