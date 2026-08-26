import AppKit

/// The text view inside a ``NotesEditorView``.
///
/// Return and Escape both have a window-level meaning the note has to take back:
/// a hosting sheet's default button would swallow Return, and the field's own
/// cancel has to revert the buffer before anything dismisses the host.
@MainActor
private final class NotesTextView: NSTextView {
    var onCommandReturn: (() -> Void)?
    var onCancel: (() -> Void)?

    /// Return types a newline into the note instead of firing a host's default
    /// button; ⌘-Return commits.
    ///
    /// Key equivalents are dispatched before the first responder sees the key
    /// down, so a default button would otherwise take Return out from under a
    /// note being typed. Handling it here consumes the event and inserts the
    /// newline in its place.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let characters = event.charactersIgnoringModifiers
        guard window?.firstResponder === self,
            characters == "\r" || characters == "\u{3}"
        else { return super.performKeyEquivalent(with: event) }

        if event.modifierFlags.contains(.command) {
            onCommandReturn?()
            return true
        }
        // A Return that confirms an input method's candidate belongs to the
        // composition, not to the note — typing a newline over it would destroy
        // what is being composed. It still can't reach the host's default
        // button, so the event is handed to the input context instead.
        guard !hasMarkedText() else {
            interpretKeyEvents([event])
            return true
        }
        insertNewline(nil)
        return true
    }

    /// Escape reverts the note and asks the host to dismiss.
    ///
    /// `NSTextView` answers `cancelOperation(_:)` itself (it drives completion),
    /// so the event never reaches a hosting popover's own Escape handling — the
    /// host is told directly instead.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The stand-in placeholder overlaying an empty ``NotesEditorView``.
///
/// It sits over the text view, so it must take no hits of its own — a click on
/// the placeholder is a click into the note.
@MainActor
private final class NotesPlaceholderLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A bordered, always-editable multi-line note box — Finder's Get Info
/// "Comments" field.
///
/// Return inserts a newline, ⌘-Return commits, Escape reverts and asks the host
/// to dismiss, and the host commits whatever is in the box when it goes away.
/// The box grows with the note between a floor and a cap, so a long note
/// scrolls rather than stretching its container.
@MainActor
final class NotesEditorView: NSView {
    /// Fires with the note as typed: on ⌘-Return, and on ``commitIfChanged()``.
    ///
    /// ⌘-Return reports whether or not the note moved, so a host that treats it
    /// as "I am done here" hears it either way.
    var onCommit: ((String) -> Void)?
    /// Fires when Escape reverted the note, so the host can dismiss.
    var onCancel: (() -> Void)?

    /// `true` once Escape reverted the note, which is what keeps the host's
    /// teardown commit from writing the reverted text back.
    private var isCancelled = false

    /// The note as it currently stands in the box.
    var text: String { textView.string }

    private static let minHeight: CGFloat = 54
    private static let maxHeight: CGFloat = 160
    /// Chrome between the box's width and the width text wraps at: the bezel,
    /// the text container's own inset, and room for the scroller.
    private static let horizontalChrome: CGFloat = 24
    /// Bezel and text-container inset above and below the wrapped text.
    private static let verticalChrome: CGFloat = 12

    private let textView = NotesTextView()
    private let scrollView = NSScrollView()
    private let placeholderLabel = NotesPlaceholderLabel(labelWithString: "")
    private var heightConstraint: NSLayoutConstraint?
    private var originalText: String

    init(text: String, placeholder: String = "Add notes\u{2026}") {
        self.originalText = text
        super.init(frame: .zero)
        placeholderLabel.stringValue = placeholder
        buildLayout(text: text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("NotesEditorView does not support NSCoder")
    }

    /// Hands the note to ``onCommit`` unless Escape already reverted it, or
    /// nothing changed — what a host calls as it tears the box down.
    func commitIfChanged() {
        guard !isCancelled, textView.string != originalText else { return }
        commit()
    }

    private func commit() {
        originalText = textView.string
        onCommit?(textView.string)
    }

    private func buildLayout(text: String) {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)

        textView.string = text
        textView.font = CalloutStyle.bodyFont
        textView.textColor = .labelColor
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.onCommandReturn = { [weak self] in self?.commit() }
        textView.onCancel = { [weak self] in self?.revert() }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true

        // `NSTextView` has no placeholder, so an overlaid label stands in for one
        // and steps aside as soon as there is a note to read.
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = CalloutStyle.bodyFont
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.isSelectable = false
        placeholderLabel.isHidden = !text.isEmpty

        addSubview(scrollView)
        addSubview(placeholderLabel)
        let height = scrollView.heightAnchor.constraint(equalToConstant: Self.minHeight)
        heightConstraint = height
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
            placeholderLabel.leadingAnchor.constraint(
                equalTo: scrollView.leadingAnchor, constant: Self.horizontalChrome / 2),
            placeholderLabel.topAnchor.constraint(
                equalTo: scrollView.topAnchor, constant: Self.verticalChrome / 2),
        ])
    }

    /// Reverts the box to the note it opened with and reports the cancel.
    private func revert() {
        isCancelled = true
        textView.string = originalText
        refreshPlaceholder()
        onCancel?()
    }

    private func refreshPlaceholder() {
        placeholderLabel.isHidden = !textView.string.isEmpty
    }

    override func layout() {
        super.layout()
        refreshHeight()
    }

    /// Grows the box with the note, floored so an empty one is still a target
    /// and capped so a long one scrolls instead of stretching the host.
    private func refreshHeight() {
        guard let heightConstraint else { return }
        let available = max(bounds.width - Self.horizontalChrome, 1)
        let measured = (textView.string as NSString).boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: CalloutStyle.bodyFont]
        ).height
        let wanted = min(
            max(ceil(measured) + Self.verticalChrome, Self.minHeight), Self.maxHeight)
        guard heightConstraint.constant != wanted else { return }
        heightConstraint.constant = wanted
    }
}

// MARK: - NSTextViewDelegate

extension NotesEditorView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        refreshPlaceholder()
        refreshHeight()
    }
}
