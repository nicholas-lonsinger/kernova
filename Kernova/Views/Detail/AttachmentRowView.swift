import AppKit

/// The editable title field for an attachment row.
///
/// It spans the row width so the inline rename box is comfortably sized, which
/// means it also covers most of the row's right-click target. In its display
/// (non-editable) state it therefore surfaces the row's lazily-built context
/// menu — which the field would otherwise swallow — via ``contextMenuProvider``;
/// while editing it falls through to the field editor's standard menu.
@MainActor
private final class RenameTitleField: NSTextField {
    var contextMenuProvider: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        if !isEditable, let menu = contextMenuProvider?() { return menu }
        return super.menu(for: event)
    }
}

/// A single attachment list row — a storage disk or a removable medium: the
/// standard attachment layout (leading icon, title + subtitle, Read Only switch)
/// plus two affordances the plain `makeListRow` rows don't have — inline rename
/// of the title and a per-row right-click context menu.
///
/// Clicking the title (when the row's controls are enabled) flips it into an
/// editable field; Return / focus-loss commits, Escape cancels. The rename
/// mechanics mirror ``SidebarVMRowCellView``. The context menu is
/// supplied lazily by the controller via ``contextMenu`` so it reflects current
/// state (the Read Only checkmark, missing-file disabling) at click time, and is
/// always where Remove lives. Removable-media rows additionally carry an inline
/// trailing minus button (hot-pluggable media is swapped often, so quick removal
/// is worth a dedicated control); storage-disk rows pass `removeButton: nil` and
/// rely on the context menu alone.
///
/// The icon, subtitle, Read Only switch, and optional remove button are built by
/// the controller (so their target/action wiring stays in one place) and handed
/// in; this view owns only the editable title and the rename state machine. The
/// `itemID` is the backing model's id (a `StorageDisk` or `RemovableMediaItem`).
@MainActor
final class AttachmentRowView: NSView, NSTextFieldDelegate {
    let itemID: UUID
    /// The leading icon view, exposed so the controller can anchor the Get Info
    /// popover to it (matching the click-the-icon affordance).
    let infoAnchor: NSView
    /// The subtitle label, exposed so the controller can (re-)populate it with
    /// the live, off-main size read.
    let subtitleField: NSTextField
    /// Accessory views the row updates in place (see ``update(title:iconSystemName:missingPath:readOnly:controlsEnabled:)``)
    /// so a refresh that only changes display state doesn't tear the row down.
    private let iconButton: AttachmentIconButton
    private let readOnlyToggle: NSSwitch
    /// Trailing inline Remove control, present only on removable-media rows; `nil`
    /// for storage disks, which remove via the context menu alone.
    private let removeButton: NSButton?
    private var controlsEnabled: Bool
    private var originalTitle: String
    private let titleField = RenameTitleField()
    /// A `<=` cap on the title's width, activated only while renaming.
    ///
    /// So the box hugs the text (growing as you type) yet never demands width and
    /// stretches the window. The title otherwise fills the column.
    private var titleEditWidth: NSLayoutConstraint?

    private var isRenaming = false
    /// Suppresses the commit path while an Escape-driven cancel tears down the
    /// field editor (ending editing would otherwise also fire a commit).
    private var isCancellingRename = false
    /// Active only while renaming: commits the current text on a click anywhere
    /// outside the title field (AppKit doesn't end field editing on
    /// empty-space clicks).
    private var outsideClickMonitor: Any?

    /// Fires when the user begins editing the title, so the controller can
    /// suppress list rebuilds that would otherwise destroy the editing field.
    var onRenameBegan: ((UUID) -> Void)?
    /// Fires with the new (untrimmed) label on Return / focus-loss.
    var onRenameCommitted: ((UUID, String) -> Void)?
    /// Fires on Escape.
    var onRenameCancelled: ((UUID) -> Void)?
    /// Supplies the right-click menu, built lazily by the controller.
    var contextMenu: (() -> NSMenu?)?

    private lazy var clickRecognizer: NSClickGestureRecognizer = {
        let recognizer = NSClickGestureRecognizer(
            target: self, action: #selector(titleClicked))
        recognizer.numberOfClicksRequired = 1
        return recognizer
    }()

    init(
        itemID: UUID,
        title: String,
        controlsEnabled: Bool,
        icon: AttachmentIconButton,
        subtitle: NSTextField,
        readOnlyToggle: NSSwitch,
        readOnlyCaption: NSView,
        removeButton: NSButton? = nil
    ) {
        self.itemID = itemID
        self.infoAnchor = icon
        self.iconButton = icon
        self.subtitleField = subtitle
        self.readOnlyToggle = readOnlyToggle
        self.removeButton = removeButton
        self.controlsEnabled = controlsEnabled
        self.originalTitle = title
        super.init(frame: .zero)
        buildLayout(
            icon: icon, subtitle: subtitle, readOnlyToggle: readOnlyToggle,
            readOnlyCaption: readOnlyCaption, removeButton: removeButton)
    }

    /// Updates the row's display state in place, without a teardown/rebuild.
    ///
    /// Used when the item set and order are unchanged — a rename, a Read Only
    /// toggle, a start/stop enabling change, or a file going missing. Rebuilding
    /// instead would recreate the subtitle field empty and re-fade its size in,
    /// so the existing field is kept; the subtitle is (re-)read by the
    /// controller, and only when the backing file changed.
    ///
    /// Never invoked mid-edit (the controller suppresses refreshes while a rename
    /// is active), but it leaves the title alone if an edit is somehow live.
    func update(
        title: String, iconSystemName: String, missingPath: String?, readOnly: Bool,
        controlsEnabled: Bool
    ) {
        self.controlsEnabled = controlsEnabled
        if !isRenaming {
            originalTitle = title
            titleField.stringValue = title
            // Guarded with the title writes: beginRename() deliberately disables
            // the recognizer for the duration of an edit, so re-enabling it here
            // mid-edit would re-arm the title click against the live field editor.
            clickRecognizer.isEnabled = controlsEnabled
        }
        readOnlyToggle.state = readOnly ? .on : .off
        readOnlyToggle.isEnabled = controlsEnabled
        removeButton?.isEnabled = controlsEnabled
        iconButton.configure(systemName: iconSystemName, missingPath: missingPath)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AttachmentRowView does not support NSCoder")
    }

    private func buildLayout(
        icon: NSView, subtitle: NSTextField, readOnlyToggle: NSView, readOnlyCaption: NSView,
        removeButton: NSButton?
    ) {
        translatesAutoresizingMaskIntoConstraints = false

        titleField.stringValue = originalTitle
        titleField.font = Typography.body
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.usesSingleLineMode = true
        titleField.cell?.isScrollable = true
        titleField.delegate = self
        // Display state: the title fills the column — a large click / right-click
        // target that truncates only when out of room. Rename state: it instead
        // hugs its text and grows as you type, clamped to the column so a long
        // name scrolls rather than the box ballooning to full width (see
        // ``beginRename()``). The column itself still claims the row's spare
        // width (below) so the box has room to grow.
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.contextMenuProvider = { [weak self] in self?.contextMenu?() }
        titleField.addGestureRecognizer(clickRecognizer)
        clickRecognizer.isEnabled = controlsEnabled

        // The title sits in a horizontal `.fill` line with a trailing spacer:
        // the field fills the column (it has the lowest hugging), and while
        // renaming `titleEditWidth` *caps* its width so the box hugs the name
        // while the spacer soaks up the slack and keeps it left-aligned. The fill
        // comes from the spacer, not an `==` on the field, and the cap is a `<=`
        // bound — so a long name fills and scrolls, and the box never demands
        // width that would stretch the detail pane (and the limitless window).
        let titleSpacer = NSView()
        titleSpacer.translatesAutoresizingMaskIntoConstraints = false
        titleSpacer.setContentHuggingPriority(.defaultLow + 1, for: .horizontal)
        titleSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleLine = NSStackView(views: [titleField, titleSpacer])
        titleLine.orientation = .horizontal
        titleLine.distribution = .fill
        titleLine.spacing = 0

        let titleEdit = titleField.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
        titleEdit.priority = .defaultHigh
        titleEditWidth = titleEdit

        let textStack = NSStackView(views: [titleLine, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Spacing.hairline
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Both rows fill the column width: the title line so it can hold its
        // spacer, the subtitle so it middle-truncates.
        NSLayoutConstraint.activate([
            titleLine.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            titleLine.trailingAnchor.constraint(equalTo: textStack.trailingAnchor),
            subtitle.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: textStack.trailingAnchor),
        ])

        // Keep the leading icon and trailing controls rigid so the text column
        // is the only view that stretches to absorb the row's spare width.
        for accessory in [icon, readOnlyToggle, removeButton].compactMap({ $0 }) {
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let row = NSStackView(views: [
            icon, textStack, readOnlyToggle, readOnlyCaption,
        ])
        if let removeButton { row.addArrangedSubview(removeButton) }
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

    // MARK: - Inline rename

    /// Begins inline editing of the title.
    ///
    /// Invoked by a title click and by the controller's "Rename" menu item.
    func beginRename() {
        guard controlsEnabled, !isRenaming, let window else { return }
        isRenaming = true
        onRenameBegan?(itemID)
        clickRecognizer.isEnabled = false
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.isBezeled = true
        titleField.drawsBackground = true
        // Cap the (still column-filling) title at the current name's width so the
        // box hugs it; re-capped as the user types.
        updateRenameBoxWidth(for: titleField.stringValue)
        titleEditWidth?.isActive = true
        window.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
        installOutsideClickMonitor()
    }

    /// Installs a local mouse-down monitor that commits the rename when the user
    /// clicks anywhere outside the title field — AppKit doesn't end field editing
    /// on clicks that land on non-focusable empty space.
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.isRenaming else { return event }
            let pointInField = self.titleField.convert(event.locationInWindow, from: nil)
            if !self.titleField.bounds.contains(pointInField) {
                // Resign the field editor → `controlTextDidEndEditing` → commit.
                self.window?.makeFirstResponder(nil)
            }
            return event
        }
    }

    /// Cancels the in-progress rename (Escape), tearing down the field editor and
    /// restoring the original label.
    ///
    /// Resigning is what actually ends the edit — setting `isEditable = false`
    /// alone leaves the field editor active and the box stuck in its editing
    /// state. The live buffer is reverted first so the resign doesn't carry the
    /// typed text into the field's value.
    private func cancelRename() {
        guard isRenaming else { return }
        isCancellingRename = true
        titleField.currentEditor()?.string = originalTitle
        window?.makeFirstResponder(nil)
        endRenameAppearance()
        isCancellingRename = false
        onRenameCancelled?(itemID)
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// Safety net: if the row is torn down (removed from its window) while a
    /// rename is somehow still active, drop the event monitor so it can't leak.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { removeOutsideClickMonitor() }
    }

    /// Reverts the field to its display appearance and restores the original
    /// label.
    ///
    /// A successful rename triggers a list rebuild that replaces this row with
    /// the new label; a rejected one (empty / unchanged) leaves the restored
    /// original showing.
    private func endRenameAppearance() {
        isRenaming = false
        removeOutsideClickMonitor()
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.isBordered = false
        titleField.isBezeled = false
        titleField.drawsBackground = false
        // Drop the text-width cap; the title goes back to filling the column.
        titleEditWidth?.isActive = false
        titleField.stringValue = originalTitle
        clickRecognizer.isEnabled = controlsEnabled
    }

    @objc private func titleClicked() {
        beginRename()
    }

    func controlTextDidChange(_ obj: Notification) {
        // Grow/shrink the box with the live text so it stays snug while typing.
        let live = titleField.currentEditor()?.string ?? titleField.stringValue
        updateRenameBoxWidth(for: live)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isRenaming, !isCancellingRename else { return }
        let newLabel = titleField.stringValue
        endRenameAppearance()
        onRenameCommitted?(itemID, newLabel)
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelRename()
        return true
    }

    // MARK: - Rename box sizing

    /// Sizes the rename box to fit `text`.
    ///
    /// The required `<=` column clamp from ``buildLayout()`` caps the result, so
    /// an over-long name leaves the box at the column width and scrolls inside it
    /// rather than the box overflowing the row. Sizing is shared with the other
    /// inline-rename surfaces via ``InlineRenameSizing``.
    private func updateRenameBoxWidth(for text: String) {
        titleEditWidth?.constant = InlineRenameSizing.boxWidth(for: text, font: Typography.body)
    }
}
