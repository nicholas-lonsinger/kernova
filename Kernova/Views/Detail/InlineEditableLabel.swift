import AppKit

/// A piece of text edited in place — by clicking it, or by a menu item that
/// arms the edit from elsewhere.
///
/// Owns the whole inline-edit state machine — the field editor's appearance,
/// the box sizing, Return/Escape, and, where it owns its clicks, the click
/// gesture and the outside-click monitor — so every inline-edited value behaves
/// identically. The owner supplies identity: the callbacks carry only the text.
///
/// It fills whatever width its container gives it, so it covers most of the
/// row's right-click target and must re-surface the row's context menu — which
/// it would otherwise swallow — via ``contextMenu``. While editing it falls
/// through to the field editor's standard menu.
///
/// Two surfaces can hold an edit of the same value at once, which is why
/// ``currentText`` exists: taking first responder can synchronously commit the
/// other surface's pending edit, changing the value after the seed.
@MainActor
final class InlineEditableLabel: NSTextField, NSTextFieldDelegate {
    /// Who tracks the clicks that begin and end an edit.
    enum ClickHandling {
        /// The label arms its own click-to-edit gesture, and while editing a
        /// local mouse-down monitor ends the edit on a click outside the box —
        /// AppKit doesn't end field editing on clicks that land on
        /// non-focusable space.
        case owned
        /// The enclosing view tracks clicks itself, so the label installs
        /// neither. A recognizer on the label would swallow the enclosing
        /// view's own selection and drag tracking, and a click there lands on a
        /// focusable view that resigns the field editor on its own — so a
        /// monitor resigning first, ahead of that view's mouse tracking, would
        /// commit and reload the list mid-dispatch.
        case delegatedToEnclosingView
    }

    /// Fires when the user begins editing, so the controller can suppress list
    /// rebuilds that would otherwise destroy the editing field.
    var onEditBegan: (() -> Void)?
    /// Fires with the new (untrimmed) text on Return / focus-loss; the `Bool` is
    /// `true` when editing ended by Return, which an owner that moves focus on
    /// its own reads.
    var onEditCommitted: ((String, Bool) -> Void)?
    /// Fires on Escape.
    var onEditCancelled: (() -> Void)?
    /// Supplies the right-click menu, built lazily by the controller.
    var contextMenu: (() -> NSMenu?)?
    /// What a click on the label does while editing is armed.
    ///
    /// `nil` begins editing in place. An owner whose text can't be held by a
    /// single-line field routes the click elsewhere instead.
    var onClicked: (() -> Void)?
    /// The authoritative text, re-read after the label takes first responder.
    ///
    /// Leave it `nil` where the value has one editing surface: the seed the
    /// edit opened with is then the only text there is.
    var currentText: (() -> String)?

    /// A `<=` cap on the label's width, activated only while editing.
    ///
    /// The bound is `<=`, not `==`, so the box hugs the text without demanding
    /// width that would stretch the pane.
    private var editWidth: NSLayoutConstraint?
    private var originalText: String
    private var controlsEnabled: Bool
    private let clickHandling: ClickHandling

    private(set) var isEditing = false
    /// Suppresses the commit path while a path that already settled the edit
    /// (Escape, or a silent abandon) resigns the field editor.
    private var isCancellingEdit = false
    /// Local mouse-down monitor, active only while editing.
    private var outsideClickMonitor: Any?

    /// Built only under ``ClickHandling/owned``.
    private var clickRecognizer: NSClickGestureRecognizer?

    init(
        text: String, font: NSFont, textColor: NSColor, placeholder: String,
        controlsEnabled: Bool, clickHandling: ClickHandling = .owned
    ) {
        self.originalText = text
        self.controlsEnabled = controlsEnabled
        self.clickHandling = clickHandling
        super.init(frame: .zero)
        configure(font: font, textColor: textColor, placeholder: placeholder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InlineEditableLabel does not support NSCoder")
    }

    /// Safety net for a label torn down while an edit is somehow still active,
    /// so the event monitor can't outlive it.
    deinit {
        MainActor.assumeIsolated { removeOutsideClickMonitor() }
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
        clickRecognizer?.isEnabled = controlsEnabled
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
        if clickHandling == .owned {
            let recognizer = NSClickGestureRecognizer(target: self, action: #selector(labelClicked))
            recognizer.numberOfClicksRequired = 1
            recognizer.isEnabled = controlsEnabled
            addGestureRecognizer(recognizer)
            clickRecognizer = recognizer
        }

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
    ///
    /// The appearance flips whether or not the label is in a window yet: a row
    /// configured during a list reload is armed before it joins one, and
    /// ``viewDidMoveToWindow()`` takes focus when it does.
    func beginEditing() {
        guard controlsEnabled, !isEditing else { return }
        isEditing = true
        onEditBegan?()
        clickRecognizer?.isEnabled = false
        isEditable = true
        isSelectable = true
        isBezeled = true
        drawsBackground = true
        // Cap the (still column-filling) label at the current text's width so the
        // box hugs it; re-capped as the user types.
        updateEditBoxWidth(for: stringValue)
        editWidth?.isActive = true
        takeFocus()
    }

    /// Ends an in-flight edit through the commit path.
    ///
    /// Callers run it unconditionally on every refresh, so it no-ops when
    /// nothing is being edited.
    func endEditing() {
        guard isEditing else { return }
        guard currentEditor() != nil else {
            // Armed but never focused, so there is no typed text to commit.
            endEditAppearance()
            return
        }
        // Resigning is the one commit path: `controlTextDidEndEditing` →
        // `endEditAppearance()` → `onEditCommitted`.
        window?.makeFirstResponder(nil)
    }

    /// Drops an in-flight edit without committing or cancelling it.
    ///
    /// For a view recycled out from under a live edit: the typed text belongs
    /// to a row that is no longer there, so neither callback fires.
    func abandonEditing() {
        revertAndResign()
    }

    /// Takes first responder so the user can type, and seeds the editor.
    ///
    /// No-ops without a window; ``viewDidMoveToWindow()`` runs it again when
    /// one arrives.
    private func takeFocus() {
        guard let window else { return }
        window.makeFirstResponder(self)
        reseedFromCurrentText()
        currentEditor()?.selectAll(nil)
        if clickHandling == .owned { installOutsideClickMonitor() }
    }

    /// Re-reads ``currentText`` now that the label holds first responder.
    ///
    /// Taking focus can synchronously commit another surface's pending edit of
    /// the same value, changing it after the seed — and that mutation lands
    /// inside this very pass, so no later pass repairs an already-open box.
    /// `originalText` moves with it, so Escape reverts to the handed-off text.
    private func reseedFromCurrentText() {
        guard let text = currentText?(), text != stringValue else { return }
        originalText = text
        stringValue = text
        currentEditor()?.string = text
        updateEditBoxWidth(for: text)
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
    private func cancelEditing() {
        guard isEditing else { return }
        revertAndResign()
        onEditCancelled?()
    }

    /// Reverts to the display state, dropping any in-flight text and firing
    /// nothing.
    ///
    /// Resigning is what actually ends the edit — setting `isEditable = false`
    /// alone leaves the field editor active and the box stuck in its editing
    /// state. The live buffer is reverted first so the resign doesn't carry the
    /// typed text into the field's value, and the resulting end-editing
    /// notification is kept off the commit path.
    private func revertAndResign() {
        guard isEditing else { return }
        isCancellingEdit = true
        currentEditor()?.string = originalText
        window?.makeFirstResponder(nil)
        endEditAppearance()
        isCancellingEdit = false
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// Takes focus for an edit armed before the label had a window, and — on
    /// the way out — drops the event monitor so it can't leak.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            removeOutsideClickMonitor()
            return
        }
        if isEditing, currentEditor() == nil { takeFocus() }
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
        clickRecognizer?.isEnabled = controlsEnabled
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
        let endedByReturn =
            (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue
        endEditAppearance()
        onEditCommitted?(newText, endedByReturn)
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
