import AppKit
import KernovaCore

/// A single attachment list row — a storage disk, a removable medium, or a
/// shared directory.
///
/// The controller builds the icon, subtitle, Read Only switch, and optional eject
/// button and hands them in; the editable name and note, and their edit state
/// machine, live in ``EditableRowTitleView``. The context menu is supplied lazily
/// via ``contextMenu`` so it reflects current state at click time. `itemID` is
/// the backing model's id (a `StorageDisk`, `RemovableMediaItem` or
/// `SharedDirectory`).
@MainActor
final class AttachmentRowView: NSView {
    let itemID: UUID
    /// Whether the name and note take an inline edit at all — `false` for a row
    /// whose model holds neither a label nor a note of its own, whose other
    /// controls stay live.
    private let isTitleEditable: Bool
    /// The leading icon view, exposed so the controller can anchor the Get Info
    /// popover to it.
    let infoAnchor: NSView
    private let subtitleField: NSTextField
    private let iconButton: AttachmentIconButton
    private let readOnlyToggle: NSSwitch
    /// Beside the Read Only switch of an entry whose bookmark grants reading
    /// alone, saying why it stays on; hidden on every other row.
    private let readOnlyInfo = InfoButtonView()
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
        readAccessOnly: ReadAccessOnly?,
        ejectButton: NSButton? = nil,
        isTitleEditable: Bool = true
    ) {
        self.itemID = itemID
        self.isTitleEditable = isTitleEditable
        self.infoAnchor = icon
        self.iconButton = icon
        self.subtitleField = subtitle
        self.readOnlyToggle = readOnlyToggle
        self.ejectButton = ejectButton
        self.titleView = EditableRowTitleView(
            itemID: itemID, name: title, notes: notes,
            controlsEnabled: controlsEnabled && isTitleEditable)
        super.init(frame: .zero)
        layOutEditableListRow(
            in: self, icon: icon, title: titleView, subtitle: subtitle,
            trailing: [readOnlyToggle, readOnlyCaption, readOnlyInfo, ejectButton].compactMap { $0 })
        applyReadOnlyEdit(controlsEnabled: controlsEnabled, readAccessOnly: readAccessOnly)
    }

    /// Updates the row's display state to `model`'s in place, without a
    /// teardown/rebuild; the title view leaves an edit in progress alone.
    ///
    /// `missingPath`, when set, replaces `subtitle` with the missing state.
    func update(_ model: VMSettingsRenderedRow) {
        updateAttachmentSubtitle(subtitleField, text: model.subtitle, missingPath: model.missingPath)
        titleView.update(
            name: model.title, notes: model.notes, controlsEnabled: model.controlsEnabled && isTitleEditable)
        readOnlyToggle.state = model.readOnly ? .on : .off
        applyReadOnlyEdit(controlsEnabled: model.controlsEnabled, readAccessOnly: model.readAccessOnly)
        ejectButton?.isEnabled = model.ejectEnabled
        iconButton.configure(systemName: model.iconSystemName, missingPath: model.missingPath)
    }

    /// Lets the Read Only switch take an edit while `controlsEnabled`, except
    /// on an entry `readAccessOnly` holds Read Only, which shows why beside it.
    private func applyReadOnlyEdit(controlsEnabled: Bool, readAccessOnly: ReadAccessOnly?) {
        readOnlyToggle.isEnabled = controlsEnabled && readAccessOnly == nil
        readOnlyInfo.isHidden = readAccessOnly == nil
        if let readAccessOnly {
            readOnlyInfo.configure(
                label: "Read Only", paragraphs: [.body(readAccessOnly.reason), .body(readAccessOnly.remedy)])
        }
    }

    /// Begins inline editing of the title, the box holding `draft` in place
    /// of it when one is given.
    func beginRename(holding draft: String? = nil) {
        titleView.beginRename(holding: draft)
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

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?()
    }
}
