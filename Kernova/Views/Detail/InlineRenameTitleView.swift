import AppKit

/// The editable title field for a settings-list row.
///
/// It spans the row width, so it covers most of the row's right-click target and
/// must re-surface the row's context menu — which it would otherwise swallow —
/// via ``contextMenuProvider``. While editing it falls through to the field
/// editor's standard menu.
@MainActor
private final class RenameTitleField: NSTextField {
    var contextMenuProvider: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        if !isEditable, let menu = contextMenuProvider?() { return menu }
        return super.menu(for: event)
    }
}

/// A list row's title, renamed in place by clicking it or by a "Rename" menu
/// item.
///
/// Owns the whole rename state machine — the click gesture, the field editor's
/// appearance, the box sizing, the outside-click monitor, and Return/Escape —
/// so every list that renames a row inline behaves identically. `itemID` is the
/// backing model's id, echoed back through the callbacks.
@MainActor
final class InlineRenameTitleView: NSView, NSTextFieldDelegate {
    let itemID: UUID

    /// Fires when the user begins editing, so the controller can suppress list
    /// rebuilds that would otherwise destroy the editing field.
    var onRenameBegan: ((UUID) -> Void)?
    /// Fires with the new (untrimmed) label on Return / focus-loss.
    var onRenameCommitted: ((UUID, String) -> Void)?
    /// Fires on Escape.
    var onRenameCancelled: ((UUID) -> Void)?
    /// Supplies the right-click menu, built lazily by the controller.
    var contextMenu: (() -> NSMenu?)?

    private let titleField = RenameTitleField()
    /// A `<=` cap on the title's width, activated only while renaming.
    ///
    /// The bound is `<=`, not `==`, so the box hugs the name without demanding
    /// width that would stretch the pane.
    private var titleEditWidth: NSLayoutConstraint?
    private var originalTitle: String
    private var controlsEnabled: Bool

    private var isRenaming = false
    /// Suppresses the commit path while an Escape-driven cancel tears down the
    /// field editor (ending editing would otherwise also fire a commit).
    private var isCancellingRename = false
    /// Local mouse-down monitor, active only while renaming.
    private var outsideClickMonitor: Any?

    private lazy var clickRecognizer: NSClickGestureRecognizer = {
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(titleClicked))
        recognizer.numberOfClicksRequired = 1
        return recognizer
    }()

    init(itemID: UUID, title: String, controlsEnabled: Bool) {
        self.itemID = itemID
        self.originalTitle = title
        self.controlsEnabled = controlsEnabled
        super.init(frame: .zero)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InlineRenameTitleView does not support NSCoder")
    }

    /// Updates the displayed title and whether click-to-rename is armed.
    ///
    /// An in-flight edit is left alone — re-enabling the recognizer mid-edit
    /// would re-arm the title click against the live field editor.
    func update(title: String, controlsEnabled: Bool) {
        self.controlsEnabled = controlsEnabled
        guard !isRenaming else { return }
        originalTitle = title
        titleField.stringValue = title
        clickRecognizer.isEnabled = controlsEnabled
    }

    private func buildLayout() {
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
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.contextMenuProvider = { [weak self] in self?.contextMenu?() }
        titleField.addGestureRecognizer(clickRecognizer)
        clickRecognizer.isEnabled = controlsEnabled

        // The title sits in a horizontal `.fill` line with a trailing spacer: the
        // field fills the column (lowest hugging), and while renaming
        // `titleEditWidth` caps its width so the box hugs the name while the
        // spacer soaks up the slack and keeps it left-aligned.
        let titleSpacer = NSView()
        titleSpacer.translatesAutoresizingMaskIntoConstraints = false
        titleSpacer.setContentHuggingPriority(.defaultLow + 1, for: .horizontal)
        titleSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleLine = NSStackView(views: [titleField, titleSpacer])
        titleLine.orientation = .horizontal
        titleLine.distribution = .fill
        titleLine.spacing = 0
        titleLine.translatesAutoresizingMaskIntoConstraints = false

        let titleEdit = titleField.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
        titleEdit.priority = .defaultHigh
        titleEditWidth = titleEdit

        addSubview(titleLine)
        NSLayoutConstraint.activate([
            titleLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLine.topAnchor.constraint(equalTo: topAnchor),
            titleLine.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?()
    }

    // MARK: - Inline rename

    /// Begins inline editing of the title.
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

    /// Cancels the in-progress rename (Escape).
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
    private func endRenameAppearance() {
        isRenaming = false
        removeOutsideClickMonitor()
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.isBordered = false
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleEditWidth?.isActive = false
        titleField.stringValue = originalTitle
        clickRecognizer.isEnabled = controlsEnabled
    }

    @objc private func titleClicked() {
        beginRename()
    }

    func controlTextDidChange(_ obj: Notification) {
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

    /// Sizes the rename box to fit `text`; the `<=` column cap clamps the result,
    /// so an over-long name scrolls inside the box instead of overflowing the row.
    private func updateRenameBoxWidth(for text: String) {
        titleEditWidth?.constant = InlineRenameSizing.boxWidth(for: text, font: Typography.body)
    }
}
