import AppKit

/// Root view of the clipboard window's content: accepts drag-and-drop into
/// the buffer and anchors the responder chain when no text view has focus.
///
/// Drop handling is delegated through closures so the view stays dumb: the
/// owning view controller decides whether drops are currently accepted and
/// what to do with the dragged pasteboard.
@MainActor
final class ClipboardDropContainerView: NSView {
    /// Pasteboard types that light up the drop highlight.
    ///
    /// Anything the intake path can use — files, file *promises* (what the
    /// screenshot thumbnail, Photos, and browsers drag), images, rich text,
    /// plain text. Promise types must be registered explicitly or
    /// promise-only drags never even reach `draggingEntered`.
    static let acceptedDragTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .png, .tiff, .pdf, .rtf, .html, .string]
        + NSFilePromiseReceiver.readableDraggedTypes.map(NSPasteboard.PasteboardType.init(_:))

    /// Whether a drop would currently be accepted (e.g. `false` while the
    /// clipboard service is not connected).
    var canAcceptDrop: () -> Bool = { false }

    /// Handles a performed drop; returns `true` when the content was taken
    /// (or its asynchronous receipt began, for file promises).
    var onDrop: (NSDraggingInfo) -> Bool = { _ in false }

    private var isDropTargeted = false {
        didSet { applyHighlight() }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes(Self.acceptedDragTypes)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Keeps the view controller in the responder chain for `paste(_:)` /
    /// `copy(_:)` when the text editor is hidden or unfocused — AppKit
    /// inserts a view controller after its view, but only if some view in
    /// the window can take first-responder status.
    override var acceptsFirstResponder: Bool { true }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAcceptDrop(),
            sender.draggingPasteboard.availableType(from: Self.acceptedDragTypes) != nil
        else { return [] }
        isDropTargeted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTargeted = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTargeted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTargeted = false
        return onDrop(sender)
    }

    // MARK: - Highlight

    private func applyHighlight() {
        // CGColor doesn't track appearance changes, but the highlight only
        // exists for the duration of a hover — it is reapplied from scratch
        // on every drag entry.
        layer?.borderWidth = isDropTargeted ? 2 : 0
        layer?.borderColor = isDropTargeted ? NSColor.controlAccentColor.cgColor : nil
        layer?.backgroundColor =
            isDropTargeted
            ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            : nil
    }
}
