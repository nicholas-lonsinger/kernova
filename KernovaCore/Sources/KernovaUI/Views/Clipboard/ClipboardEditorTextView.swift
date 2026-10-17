import AppKit

/// `NSTextView` for the clipboard editor that diverts file / image / file-promise
/// drags to the owning controller.
///
/// An editable `NSTextView` is itself a drag destination and consumes the drag
/// before the surrounding container sees it, inserting the file's URL/path *as
/// text*. These overrides hand such drags to `onDivertedDrop`, leaving text
/// drags — and text rearranged within this editor — to the standard behavior.
@MainActor
final class ClipboardEditorTextView: NSTextView {
    /// Handles a diverted file/image/promise drop; returns `true` when taken.
    var onDivertedDrop: ((NSDraggingInfo) -> Bool)?

    /// Types whose presence diverts a drag to `onDivertedDrop`.
    ///
    /// A plain-text/RTF/HTML-only drag carries none of these and is left to
    /// the text view so normal text drag-in still works.
    private static let divertTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .png, .tiff, .pdf]
        + NSImage.imageTypes.map(NSPasteboard.PasteboardType.init(_:))
        + NSFilePromiseReceiver.readableDraggedTypes.map(NSPasteboard.PasteboardType.init(_:))

    private func shouldDivert(_ sender: NSDraggingInfo) -> Bool {
        // Never divert text the user is rearranging within this same editor.
        if let source = sender.draggingSource as? NSView,
            source === self || source.isDescendant(of: self)
        {
            return false
        }
        return sender.draggingPasteboard.availableType(from: Self.divertTypes) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        shouldDivert(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        shouldDivert(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        shouldDivert(sender) ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard shouldDivert(sender) else { return super.performDragOperation(sender) }
        return onDivertedDrop?(sender) ?? false
    }
}
