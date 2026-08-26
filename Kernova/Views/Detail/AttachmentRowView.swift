import AppKit

/// A single attachment list row — a storage disk or a removable medium.
///
/// The controller builds the icon, subtitle, Read Only switch, and optional eject
/// button and hands them in; the editable name and note, and their edit state
/// machine, live in ``EditableRowTitleView``. The context menu is supplied lazily
/// via ``contextMenu`` so it reflects current state at click time. `itemID` is
/// the backing model's id (a `StorageDisk` or `RemovableMediaItem`).
@MainActor
final class AttachmentRowView: NSView {
    let itemID: UUID
    /// The leading icon view, exposed so the controller can anchor the Get Info
    /// popover to it.
    let infoAnchor: NSView
    /// The subtitle label, exposed so the controller can (re-)populate it with
    /// the live, off-main size read.
    let subtitleField: NSTextField
    private let iconButton: AttachmentIconButton
    private let readOnlyToggle: NSSwitch
    /// Trailing inline Eject control, present only on removable-media rows.
    private let ejectButton: NSButton?
    private let titleView: EditableRowTitleView

    /// Fires when the user begins editing the title or the note, so the
    /// controller can suppress list rebuilds that would otherwise destroy the
    /// editing field.
    var onEditBegan: ((UUID) -> Void)? {
        get { titleView.onEditBegan }
        set { titleView.onEditBegan = newValue }
    }
    /// Fires with the new (untrimmed) label on Return / focus-loss.
    var onRenameCommitted: ((UUID, String) -> Void)? {
        get { titleView.onRenameCommitted }
        set { titleView.onRenameCommitted = newValue }
    }
    /// Fires on Escape.
    var onRenameCancelled: ((UUID) -> Void)? {
        get { titleView.onRenameCancelled }
        set { titleView.onRenameCancelled = newValue }
    }
    /// Fires with the new (untrimmed) note on Return / focus-loss.
    var onNotesCommitted: ((UUID, String) -> Void)? {
        get { titleView.onNotesCommitted }
        set { titleView.onNotesCommitted = newValue }
    }
    /// Fires when a note edit is cancelled with Escape.
    var onNotesCancelled: ((UUID) -> Void)? {
        get { titleView.onNotesCancelled }
        set { titleView.onNotesCancelled = newValue }
    }
    /// Fires when a note this row can't edit inline is activated.
    var onNotesOverflowActivated: ((UUID) -> Void)? {
        get { titleView.onNotesOverflowActivated }
        set { titleView.onNotesOverflowActivated = newValue }
    }
    /// Supplies the right-click menu, built lazily by the controller.
    var contextMenu: (() -> NSMenu?)? {
        didSet { titleView.contextMenu = contextMenu }
    }

    init(
        itemID: UUID,
        title: String,
        notes: String,
        controlsEnabled: Bool,
        icon: AttachmentIconButton,
        subtitle: NSTextField,
        readOnlyToggle: NSSwitch,
        readOnlyCaption: NSView,
        ejectButton: NSButton? = nil
    ) {
        self.itemID = itemID
        self.infoAnchor = icon
        self.iconButton = icon
        self.subtitleField = subtitle
        self.readOnlyToggle = readOnlyToggle
        self.ejectButton = ejectButton
        self.titleView = EditableRowTitleView(
            itemID: itemID, name: title, notes: notes, controlsEnabled: controlsEnabled)
        super.init(frame: .zero)
        buildLayout(
            icon: icon, subtitle: subtitle, readOnlyToggle: readOnlyToggle,
            readOnlyCaption: readOnlyCaption, ejectButton: ejectButton)
    }

    /// Updates the row's display state in place, without a teardown/rebuild.
    ///
    /// Never invoked mid-edit (the controller suppresses refreshes while an
    /// edit is active), but the title view leaves an edit alone if one is
    /// somehow live.
    func update(
        title: String, notes: String, iconSystemName: String, missingPath: String?,
        readOnly: Bool, controlsEnabled: Bool
    ) {
        titleView.update(name: title, notes: notes, controlsEnabled: controlsEnabled)
        readOnlyToggle.state = readOnly ? .on : .off
        readOnlyToggle.isEnabled = controlsEnabled
        ejectButton?.isEnabled = controlsEnabled
        iconButton.configure(systemName: iconSystemName, missingPath: missingPath)
    }

    /// Begins inline editing of the title.
    func beginRename() {
        titleView.beginRename()
    }

    /// Begins inline editing of the note, or hands a multi-line one to the
    /// owner's fuller editor.
    func beginNotesEditing() {
        titleView.beginNotesEditing()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AttachmentRowView does not support NSCoder")
    }

    private func buildLayout(
        icon: NSView, subtitle: NSTextField, readOnlyToggle: NSView, readOnlyCaption: NSView,
        ejectButton: NSButton?
    ) {
        translatesAutoresizingMaskIntoConstraints = false

        titleView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [titleView, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Spacing.hairline
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Both rows fill the column width: the title line so it can hold its
        // spacer, the subtitle so it middle-truncates.
        NSLayoutConstraint.activate([
            titleView.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            titleView.trailingAnchor.constraint(equalTo: textStack.trailingAnchor),
            subtitle.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: textStack.trailingAnchor),
        ])

        // Keep the leading icon and trailing controls rigid so the text column
        // is the only view that stretches to absorb the row's spare width.
        for accessory in [icon, readOnlyToggle, ejectButton].compactMap({ $0 }) {
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let row = NSStackView(views: [
            icon, textStack, readOnlyToggle, readOnlyCaption,
        ])
        if let ejectButton { row.addArrangedSubview(ejectButton) }
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Spacing.standard
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?()
    }
}
