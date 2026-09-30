import AppKit

/// Popover content shown by a snapshot row's "Get Info" menu item.
///
/// It is where a snapshot's full note is read and written: the Notes box is
/// always offered while the note can be written, so a snapshot with no note
/// yet still has somewhere to gain one.
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
    private let canEditNotes: Bool
    private var notesEditor: NotesEditorView?

    init(
        snapshot: VMSnapshot, onDiskText: String, canEditNotes: Bool,
        onCommitNotes: @escaping (String) -> Void
    ) {
        self.snapshot = snapshot
        self.onDiskText = onDiskText
        self.canEditNotes = canEditNotes
        self.onCommitNotes = onCommitNotes
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SnapshotInfoPopoverContentViewController does not support NSCoder")
    }

    /// The facts grid sets the width — the callout's standard width, or wider
    /// when a value needs it to stay on one line — and the name and notes wrap
    /// within it, so a long name never widens the popover.
    override func loadView() {
        let grid = makeFactsGrid()
        let bodyWidth = max(CalloutStyle.bodyWidth, ceil(grid.fittingSize.width))
        let headline = makeCalloutHeadline(snapshot.name)
        headline.preferredMaxLayoutWidth = bodyWidth
        installCalloutStack(
            rows: [headline, grid] + makeNotesRows(width: bodyWidth), bodyWidth: bodyWidth)
    }

    /// Commits whatever the box holds as the popover goes away — the same
    /// outcome as clicking outside it, which is what dismisses the popover.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        notesEditor?.commitIfChanged()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncCalloutContentSize()
    }

    private func makeNotesRows(width: CGFloat) -> [NSView] {
        let section = makeCalloutNotesSection(
            snapshot.notes, title: keyLabel("Notes"), canEdit: canEditNotes, width: width,
            onCommit: { [weak self] notes in self?.onCommitNotes(notes) },
            onCancel: { [weak self] in self?.onRequestClose?() })
        notesEditor = section.editor
        return section.rows
    }

    private func makeFactsGrid() -> NSGridView {
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = Spacing.hairline
        grid.columnSpacing = Spacing.standard
        grid.addRow(with: [
            keyLabel("Taken"), valueLabel(SnapshotDateFormat.string(from: snapshot.createdAt)),
        ])
        grid.addRow(with: [
            keyLabel("Captured"), valueLabel(SnapshotKindCopy.capturedContents(snapshot.kind)),
        ])
        grid.addRow(with: [keyLabel("On disk"), valueLabel(onDiskText)])
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
