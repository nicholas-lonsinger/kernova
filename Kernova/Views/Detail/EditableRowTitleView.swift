import AppKit

/// A list row's title line: the item's name, and the note that trails it.
///
/// Both parts are ``InlineEditableLabel``s, so each is edited in place by a
/// click or a menu item and the two behave identically. `itemID` is the backing
/// model's id, echoed back through the callbacks.
///
/// The note is single-line here. A note holding newlines can't be committed by
/// a single-line field without flattening it, so clicking one raises
/// ``onNotesOverflowActivated`` for the owner to open a fuller editor, and the
/// row renders it with its newlines shown as spaces.
@MainActor
final class EditableRowTitleView: NSView {
    let itemID: UUID

    /// Fires when the user begins editing either part, so the controller can
    /// suppress list rebuilds that would otherwise destroy the editing field.
    var onEditBegan: ((UUID) -> Void)?
    /// Fires with the new (untrimmed) name on Return / focus-loss.
    var onRenameCommitted: ((UUID, String) -> Void)?
    /// Fires when a name edit is cancelled with Escape.
    var onRenameCancelled: ((UUID) -> Void)?
    /// Fires with the new (untrimmed) note on Return / focus-loss.
    var onNotesCommitted: ((UUID, String) -> Void)?
    /// Fires when a note edit is cancelled with Escape.
    var onNotesCancelled: ((UUID) -> Void)?
    /// Fires when a note this row can't edit inline is activated.
    var onNotesOverflowActivated: ((UUID) -> Void)?
    /// Supplies the right-click menu, built lazily by the controller.
    var contextMenu: (() -> NSMenu?)?

    private let nameLabel: InlineEditableLabel
    private let notesLabel: InlineEditableLabel
    private var notes: String

    init(itemID: UUID, name: String, notes: String = "", controlsEnabled: Bool) {
        self.itemID = itemID
        self.notes = notes
        self.nameLabel = InlineEditableLabel(
            text: name, font: Typography.body, textColor: .labelColor, placeholder: "",
            controlsEnabled: controlsEnabled)
        // The same point size as the name keeps the line reading as one phrase;
        // the colour is what separates the note from what it annotates.
        self.notesLabel = InlineEditableLabel(
            text: Self.singleLine(notes), font: Typography.body,
            textColor: .secondaryLabelColor, placeholder: "Notes",
            controlsEnabled: controlsEnabled)
        super.init(frame: .zero)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditableRowTitleView does not support NSCoder")
    }

    /// Updates what the line displays and whether click-to-edit is armed.
    func update(name: String, notes: String = "", controlsEnabled: Bool) {
        self.notes = notes
        nameLabel.update(text: name, controlsEnabled: controlsEnabled)
        notesLabel.update(text: Self.singleLine(notes), controlsEnabled: controlsEnabled)
        refreshNotesVisibility()
    }

    /// Begins inline editing of the name.
    func beginRename() {
        nameLabel.beginEditing()
    }

    /// Begins inline editing of the note, or hands a multi-line one to the
    /// owner's fuller editor.
    ///
    /// The only route to a note on a row that has none: with nothing on screen
    /// to click, the row alone offers no way in.
    func beginNotesEditing() {
        guard !notesHoldsNewline else {
            onNotesOverflowActivated?(itemID)
            return
        }
        // A row with no note yet has nothing on screen to edit into.
        notesLabel.isHidden = false
        notesLabel.beginEditing()
    }

    private var notesHoldsNewline: Bool {
        notes.contains(where: \.isNewline)
    }

    /// The note as one line, so a pasted multi-line note still reads in the row.
    private static func singleLine(_ notes: String) -> String {
        notes.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private func refreshNotesVisibility() {
        notesLabel.isHidden = notes.isEmpty && !notesLabel.isEditing
        notesLabel.toolTip = notes.isEmpty ? nil : notes
    }

    private func buildLayout() {
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.contextMenu = { [weak self] in self?.contextMenu?() }
        nameLabel.onEditBegan = { [weak self] in
            guard let self else { return }
            self.onEditBegan?(self.itemID)
        }
        nameLabel.onEditCommitted = { [weak self] text, _ in
            guard let self else { return }
            self.onRenameCommitted?(self.itemID, text)
        }
        nameLabel.onEditCancelled = { [weak self] in
            guard let self else { return }
            self.onRenameCancelled?(self.itemID)
        }

        notesLabel.contextMenu = { [weak self] in self?.contextMenu?() }
        notesLabel.onEditBegan = { [weak self] in
            guard let self else { return }
            self.onEditBegan?(self.itemID)
        }
        notesLabel.onEditCommitted = { [weak self] text, _ in
            guard let self else { return }
            // Re-hide an empty note straight away; a committed one re-appears
            // when the owner feeds the stored value back through ``update``.
            self.refreshNotesVisibility()
            self.onNotesCommitted?(self.itemID, text)
        }
        notesLabel.onEditCancelled = { [weak self] in
            guard let self else { return }
            self.refreshNotesVisibility()
            self.onNotesCancelled?(self.itemID)
        }
        notesLabel.onClicked = { [weak self] in self?.beginNotesEditing() }
        refreshNotesVisibility()

        // A long name crowds out its note rather than the other way round, so the
        // name resists compression harder and the note tail-truncates first.
        nameLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)

        // The trailing spacer is the only view that stretches, so both labels hug
        // their own text and the line stays left-aligned — which is also what an
        // edit box that hugs what is being typed needs.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let line = NSStackView(views: [nameLabel, notesLabel, spacer])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.distribution = .fill
        line.spacing = Spacing.small
        line.translatesAutoresizingMaskIntoConstraints = false

        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?()
    }
}
