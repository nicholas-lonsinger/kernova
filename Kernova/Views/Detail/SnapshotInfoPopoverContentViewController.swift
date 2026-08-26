import AppKit

/// Popover content shown by a snapshot row's "Get Info" menu item.
///
/// It is where a snapshot's full note is read and written: the Notes box is
/// always offered while the list can be edited, so a snapshot with no note yet
/// still has somewhere to gain one.
@MainActor
final class SnapshotInfoPopoverContentViewController: NSViewController {
    /// Fires with the edited note when the box commits.
    private let onCommitNotes: (String) -> Void
    /// Fires when Escape reverted the note, so the host can dismiss the popover.
    var onRequestClose: (() -> Void)?

    private let snapshot: VMSnapshot
    /// Bytes the captured copies occupy, already formatted.
    private let onDiskText: String
    /// Whether the snapshot's note can be written right now.
    private let canEdit: Bool
    private var notesEditor: NotesEditorView?

    init(
        snapshot: VMSnapshot, onDiskText: String, canEdit: Bool,
        onCommitNotes: @escaping (String) -> Void
    ) {
        self.snapshot = snapshot
        self.onDiskText = onDiskText
        self.canEdit = canEdit
        self.onCommitNotes = onCommitNotes
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SnapshotInfoPopoverContentViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CalloutStyle.verticalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(makeCalloutHeadline(snapshot.name))
        stack.addArrangedSubview(makeFactsGrid())
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

    /// The Notes section: an editable box while the list can be written, and
    /// otherwise the note as static text — omitted entirely when there is no
    /// note to read and no way to add one.
    private func makeNotesRows() -> [NSView] {
        guard canEdit else {
            guard !snapshot.notes.isEmpty else { return [] }
            return [keyLabel("Notes"), makeCalloutBody(snapshot.notes, color: .labelColor)]
        }
        let editor = NotesEditorView(text: snapshot.notes)
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
        grid.addRow(with: [
            keyLabel("Taken"), valueLabel(SnapshotDateFormat.string(from: snapshot.createdAt)),
        ])
        grid.addRow(with: [keyLabel("Captured"), valueLabel(Self.capturedText(snapshot.kind))])
        grid.addRow(with: [keyLabel("On disk"), valueLabel(onDiskText)])
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading
        return grid
    }

    /// What the snapshot holds, in outcome terms.
    static func capturedText(_ kind: VMSnapshotKind) -> String {
        switch kind {
        case .warm: "Memory and disks"
        case .cold: "Disks only"
        }
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
