import AppKit

/// One piece of a list row's text, edited in place by clicking it or by a menu
/// item.
///
/// Owns the whole inline-edit state machine — the click gesture, the field
/// editor's appearance, the box sizing, the outside-click monitor, and
/// Return/Escape — so every inline-edited label behaves identically. The owning
/// row supplies identity: the callbacks carry only the text.
///
/// It fills whatever width its container gives it, so it covers most of the
/// row's right-click target and must re-surface the row's context menu — which
/// it would otherwise swallow — via ``contextMenu``. While editing it falls
/// through to the field editor's standard menu.
@MainActor
final class InlineEditableLabel: NSTextField, NSTextFieldDelegate {
    /// Fires when the user begins editing, so the controller can suppress list
    /// rebuilds that would otherwise destroy the editing field.
    var onEditBegan: (() -> Void)?
    /// Fires with the new (untrimmed) text on Return / focus-loss.
    var onEditCommitted: ((String) -> Void)?
    /// Fires on Escape.
    var onEditCancelled: (() -> Void)?
    /// Supplies the right-click menu, built lazily by the controller.
    var contextMenu: (() -> NSMenu?)?
    /// What a click on the label does while editing is armed.
    ///
    /// `nil` begins editing in place. An owner whose text can't be held by a
    /// single-line field routes the click elsewhere instead.
    var onClicked: (() -> Void)?

    /// A `<=` cap on the label's width, activated only while editing.
    ///
    /// The bound is `<=`, not `==`, so the box hugs the text without demanding
    /// width that would stretch the pane.
    private var editWidth: NSLayoutConstraint?
    private var originalText: String
    private var controlsEnabled: Bool

    private(set) var isEditing = false
    /// Suppresses the commit path while an Escape-driven cancel tears down the
    /// field editor (ending editing would otherwise also fire a commit).
    private var isCancellingEdit = false
    /// Local mouse-down monitor, active only while editing.
    private var outsideClickMonitor: Any?

    private lazy var clickRecognizer: NSClickGestureRecognizer = {
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(labelClicked))
        recognizer.numberOfClicksRequired = 1
        return recognizer
    }()

    init(
        text: String, font: NSFont, textColor: NSColor, placeholder: String,
        controlsEnabled: Bool
    ) {
        self.originalText = text
        self.controlsEnabled = controlsEnabled
        super.init(frame: .zero)
        configure(font: font, textColor: textColor, placeholder: placeholder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InlineEditableLabel does not support NSCoder")
    }

    /// Updates the displayed text and whether click-to-edit is armed.
    ///
    /// An in-flight edit is left alone — re-enabling the recognizer mid-edit
    /// would re-arm the click against the live field editor.
    func update(text: String, controlsEnabled: Bool) {
        self.controlsEnabled = controlsEnabled
        guard !isEditing else { return }
        originalText = text
        stringValue = text
        clickRecognizer.isEnabled = controlsEnabled
    }

    private func configure(font: NSFont, textColor: NSColor, placeholder: String) {
        translatesAutoresizingMaskIntoConstraints = false
        stringValue = originalText
        self.font = font
        self.textColor = textColor
        placeholderString = placeholder
        isBordered = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        usesSingleLineMode = true
        cell?.isScrollable = true
        delegate = self
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addGestureRecognizer(clickRecognizer)
        clickRecognizer.isEnabled = controlsEnabled

        let cap = widthAnchor.constraint(lessThanOrEqualToConstant: 0)
        cap.priority = .defaultHigh
        editWidth = cap
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        if !isEditable, let menu = contextMenu?() { return menu }
        return super.menu(for: event)
    }

    // MARK: - Inline edit

    /// Begins inline editing of the text.
    func beginEditing() {
        guard controlsEnabled, !isEditing, let window else { return }
        isEditing = true
        onEditBegan?()
        clickRecognizer.isEnabled = false
        isEditable = true
        isSelectable = true
        isBezeled = true
        drawsBackground = true
        // Cap the (still column-filling) label at the current text's width so the
        // box hugs it; re-capped as the user types.
        updateEditBoxWidth(for: stringValue)
        editWidth?.isActive = true
        window.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
        installOutsideClickMonitor()
    }

    /// Installs a local mouse-down monitor that commits the edit when the user
    /// clicks anywhere outside the field — AppKit doesn't end field editing on
    /// clicks that land on non-focusable empty space.
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.isEditing else { return event }
            let pointInField = self.convert(event.locationInWindow, from: nil)
            if !self.bounds.contains(pointInField) {
                // Resign the field editor → `controlTextDidEndEditing` → commit.
                self.window?.makeFirstResponder(nil)
            }
            return event
        }
    }

    /// Cancels the in-progress edit (Escape).
    ///
    /// Resigning is what actually ends the edit — setting `isEditable = false`
    /// alone leaves the field editor active and the box stuck in its editing
    /// state. The live buffer is reverted first so the resign doesn't carry the
    /// typed text into the field's value.
    private func cancelEditing() {
        guard isEditing else { return }
        isCancellingEdit = true
        currentEditor()?.string = originalText
        window?.makeFirstResponder(nil)
        endEditAppearance()
        isCancellingEdit = false
        onEditCancelled?()
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// Safety net: if the row is torn down (removed from its window) while an
    /// edit is somehow still active, drop the event monitor so it can't leak.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { removeOutsideClickMonitor() }
    }

    /// Reverts the field to its display appearance and restores the original
    /// text.
    private func endEditAppearance() {
        isEditing = false
        removeOutsideClickMonitor()
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        editWidth?.isActive = false
        stringValue = originalText
        clickRecognizer.isEnabled = controlsEnabled
    }

    @objc private func labelClicked() {
        if let onClicked {
            onClicked()
        } else {
            beginEditing()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        let live = currentEditor()?.string ?? stringValue
        updateEditBoxWidth(for: live)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isEditing, !isCancellingEdit else { return }
        let newText = stringValue
        endEditAppearance()
        onEditCommitted?(newText)
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelEditing()
        return true
    }

    // MARK: - Edit box sizing

    /// Sizes the edit box to fit `text`; the `<=` column cap clamps the result,
    /// so over-long text scrolls inside the box instead of overflowing the row.
    private func updateEditBoxWidth(for text: String) {
        editWidth?.constant = InlineRenameSizing.boxWidth(
            for: text, font: font ?? Typography.body)
    }
}
