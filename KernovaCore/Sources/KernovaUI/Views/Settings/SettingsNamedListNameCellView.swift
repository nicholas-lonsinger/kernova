import AppKit

/// A ``SettingsNamedListEditor`` row's name, renamed in place.
///
/// Clicks belong to the table, whose ``InPlaceRenameClicks`` opens the
/// rename, as a sidebar row's name's do.
@MainActor
final class SettingsNamedListNameCellView: NSTableCellView {
    /// What committing and cancelling a rename run.
    struct Renaming {
        /// Runs with the typed text.
        let commit: (String) -> Void
        let cancel: () -> Void
    }

    private let label = InlineEditableLabel(
        text: "", font: Typography.body, textColor: .labelColor, placeholder: "", controlsEnabled: true,
        clickHandling: .delegatedToEnclosingView)
    private var renaming: Renaming?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.allowsExpansionToolTips = true
        label.onEditCommitted = { [weak self] text, _ in self?.renaming?.commit(text) }
        label.onEditCancelled = { [weak self] in self?.renaming?.cancel() }
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.tight),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.tight),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsNamedListNameCellView does not support NSCoder")
    }

    /// Shows `name`, renamed in place through `renaming`.
    func configure(name: String, renaming: Renaming) {
        // Self-guards mid-rename, leaving the open box's text alone.
        label.update(text: name, controlsEnabled: true)
        self.renaming = renaming
    }

    /// `true` while the name is in its editable rename state.
    var isRenaming: Bool { label.isEditing }

    /// Opens the rename box, holding `draft` in place of the name when one is
    /// given.
    func beginRename(holding draft: String? = nil) {
        label.beginEditing(holding: draft)
    }

    /// Ends a live rename through the commit path, so the in-flight text lands.
    func endRename() {
        label.endEditing()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Silently: the typed name belongs to the item the cell used to show.
        label.abandonEditing()
        renaming = nil
    }
}
