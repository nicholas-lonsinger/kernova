import AppKit

/// The editable title field for a storage-disk row.
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

/// A single Storage Disks list row: the standard attachment layout (leading
/// icon, title + subtitle, Read Only switch, remove button) plus two
/// affordances the plain `makeListRow` rows don't have — inline rename of the
/// title and a per-row right-click context menu.
///
/// Double-clicking the title (when the row's controls are enabled) flips it
/// into an editable field; Return / focus-loss commits, Escape cancels. The
/// rename mechanics mirror ``SidebarVMRowCellView``. The context menu is
/// supplied lazily by the controller via ``contextMenu`` so it reflects current
/// state (the Read Only checkmark, missing-file disabling) at click time.
///
/// The icon, subtitle, Read Only switch, and remove button are built by the
/// controller (so their target/action wiring stays in one place) and handed in;
/// this view owns only the editable title and the rename state machine.
@MainActor
final class StorageDiskRowView: NSView, NSTextFieldDelegate {
    let diskID: UUID
    /// The leading icon view, exposed so the controller can anchor the Get Info
    /// popover to it (matching the click-the-icon affordance).
    let infoAnchor: NSView
    /// The subtitle label, exposed so the controller can (re-)populate it with
    /// the live, off-main size read on every refresh.
    let subtitleField: NSTextField
    private let controlsEnabled: Bool
    private let originalTitle: String
    private let titleField = RenameTitleField()
    /// Title-field width constraints toggled by ``beginRename()`` /
    /// ``endRenameAppearance()``: the title fills the column in its display
    /// state and hugs its text (growing as you type) while renaming.
    private var titleFillWidth: NSLayoutConstraint?
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

    private lazy var doubleClickRecognizer: NSClickGestureRecognizer = {
        let recognizer = NSClickGestureRecognizer(
            target: self, action: #selector(titleDoubleClicked))
        recognizer.numberOfClicksRequired = 2
        return recognizer
    }()

    init(
        diskID: UUID,
        title: String,
        controlsEnabled: Bool,
        icon: NSView,
        subtitle: NSTextField,
        readOnlyToggle: NSView,
        readOnlyCaption: NSView,
        deleteButton: NSView
    ) {
        self.diskID = diskID
        self.infoAnchor = icon
        self.subtitleField = subtitle
        self.controlsEnabled = controlsEnabled
        self.originalTitle = title
        super.init(frame: .zero)
        buildLayout(
            icon: icon, subtitle: subtitle, readOnlyToggle: readOnlyToggle,
            readOnlyCaption: readOnlyCaption, deleteButton: deleteButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StorageDiskRowView does not support NSCoder")
    }

    private func buildLayout(
        icon: NSView, subtitle: NSTextField, readOnlyToggle: NSView, readOnlyCaption: NSView,
        deleteButton: NSView
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
        titleField.addGestureRecognizer(doubleClickRecognizer)
        doubleClickRecognizer.isEnabled = controlsEnabled

        let textStack = NSStackView(views: [titleField, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Spacing.hairline
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The vertical stack's `.leading` alignment pins only the leading edge.
        // `titleFillWidth` makes the title fill the column in its display state;
        // `titleEditWidth` (active only while renaming) sizes it to its text. A
        // required `<=` clamp caps both so the box can't exceed the column — a
        // longer-than-column name scrolls inside it. The subtitle always fills
        // and middle-truncates.
        let titleFill = titleField.trailingAnchor.constraint(equalTo: textStack.trailingAnchor)
        titleFill.priority = .defaultHigh
        let titleEdit = titleField.widthAnchor.constraint(equalToConstant: 0)
        titleEdit.priority = .defaultHigh
        titleFillWidth = titleFill
        titleEditWidth = titleEdit
        NSLayoutConstraint.activate([
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: textStack.trailingAnchor),
            titleFill,
            subtitle.trailingAnchor.constraint(equalTo: textStack.trailingAnchor),
        ])

        // Keep the leading icon and trailing controls rigid so the text column
        // is the only view that stretches to absorb the row's spare width.
        for accessory in [icon, readOnlyToggle, deleteButton] {
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let row = NSStackView(views: [
            icon, textStack, readOnlyToggle, readOnlyCaption, deleteButton,
        ])
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
    /// Invoked by a title double-click and by the controller's "Rename" menu
    /// item.
    func beginRename() {
        guard controlsEnabled, !isRenaming, let window else { return }
        isRenaming = true
        onRenameBegan?(diskID)
        doubleClickRecognizer.isEnabled = false
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.isBordered = true
        titleField.bezelStyle = .roundedBezel
        titleField.drawsBackground = true
        // Swap the column-filling width for a content-hugging box sized to the
        // current name.
        titleFillWidth?.isActive = false
        updateRenameBoxWidth(for: titleField.stringValue)
        titleEditWidth?.isActive = true
        window.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
        installOutsideClickMonitor()
    }

    /// Installs a local mouse-down monitor that commits the rename when the user
    /// clicks anywhere outside the title field — AppKit doesn't end field
    /// editing on clicks that land on non-focusable empty space.
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
        titleField.drawsBackground = false
        // Back to filling the column for the display label.
        titleEditWidth?.isActive = false
        titleFillWidth?.isActive = true
        titleField.stringValue = originalTitle
        doubleClickRecognizer.isEnabled = controlsEnabled
    }

    @objc private func titleDoubleClicked() {
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
        onRenameCommitted?(diskID, newLabel)
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        isCancellingRename = true
        endRenameAppearance()
        isCancellingRename = false
        onRenameCancelled?(diskID)
        return true
    }

    // MARK: - Rename box sizing

    /// Extra width added beyond the measured rename-box width.
    ///
    /// Kept at zero: ``titleMeasuringField`` already measures the rounded-bezel
    /// chrome, whose own right-hand inset (~4 pt) houses the caret, so the box
    /// hugs the text as tightly as Finder's. Grow-as-you-type keeps it sized to
    /// the live text, so the caret never needs surplus room. Nudge up a couple
    /// points only if a caret ever clips.
    private static let renameBoxHorizontalPadding: CGFloat = 0
    /// Floor so a very short or momentarily empty name still has a usable box.
    private static let renameBoxMinWidth: CGFloat = 48

    /// Sizes the rename box to fit `text` (plus a little breathing room), floored
    /// at a small minimum.
    ///
    /// The required `<=` column clamp from ``buildLayout()`` caps the result, so
    /// an over-long name leaves the box at the column width and scrolls inside it
    /// rather than the box overflowing the row.
    private func updateRenameBoxWidth(for text: String) {
        let measured = Self.measuredTitleWidth(for: text)
        titleEditWidth?.constant = max(
            measured + Self.renameBoxHorizontalPadding, Self.renameBoxMinWidth)
    }

    /// Field reused to measure a title's width for the rename box.
    ///
    /// Configured with the *same* rounded-bezel chrome the live editing field
    /// uses, so `fittingSize` already includes that bezel's insets — the box
    /// then hugs the text instead of leaving the slack a borderless measurement
    /// (whose insets are smaller) would.
    private static let titleMeasuringField: NSTextField = {
        let field = NSTextField()
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.isEditable = false
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        return field
    }()

    private static func measuredTitleWidth(for text: String) -> CGFloat {
        titleMeasuringField.font = Typography.body
        titleMeasuringField.stringValue = text
        return ceil(titleMeasuringField.fittingSize.width)
    }
}
