import AppKit
import UniformTypeIdentifiers

/// Root view of the clipboard window's content: accepts drag-and-drop into
/// the buffer and anchors the responder chain when no text view has focus.
///
/// Drop handling is delegated through closures so the view stays dumb: the
/// owning view controller decides whether drops are currently accepted and
/// what to do with the dragged pasteboard.
@MainActor
final class ClipboardDropContainerView: NSView {
    /// Pasteboard types the window accepts as a drop.
    ///
    /// Anything the intake path can use — files, file *promises* (what the
    /// screenshot thumbnail, Photos, and browsers drag), images, rich text
    /// (including flat-RTFD, the only carrier of an inline image), plain text.
    /// Promise types must be registered explicitly or promise-only drags never
    /// even reach `draggingEntered`.
    static let acceptedDragTypes: [NSPasteboard.PasteboardType] =
        [
            .fileURL, .png, .tiff, .pdf,
            NSPasteboard.PasteboardType(UTType.flatRTFD.identifier), .rtf, .html, .string,
        ]
        + NSImage.imageTypes.map(NSPasteboard.PasteboardType.init(_:))
        + NSFilePromiseReceiver.readableDraggedTypes.map(NSPasteboard.PasteboardType.init(_:))

    /// Whether a drop would currently be accepted (e.g. `false` while the
    /// clipboard service is not connected).
    var canAcceptDrop: () -> Bool = { false }

    /// Handles a performed drop; returns `true` when the content was taken
    /// (or its asynchronous receipt began, for file promises).
    var onDrop: (NSDraggingInfo) -> Bool = { _ in false }

    init() {
        super.init(frame: .zero)
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
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop(sender)
    }
}
