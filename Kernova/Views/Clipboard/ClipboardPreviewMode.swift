import Foundation
import KernovaProtocol

/// What the clipboard window's content area shows for a given buffer.
enum ClipboardPreviewMode: Equatable {
    /// No content — an empty, editable text view (typing must keep working).
    case empty
    /// Editable text editor.
    case text(String)
    /// Read-only styled preview of inline rich text (RTF/HTML) decoded from `data`.
    case richText(data: Data, uti: String)
    /// Image preview decoded from `data`.
    case image(data: Data, uti: String)
    /// A copied/dropped file shown as a chip (icon + name + type · size).
    case file(filename: String, uti: String, byteCount: Int)
    /// Non-editable per-representation summary (unknown formats, or text too
    /// large for `NSTextView` — still sendable and copyable, just not edited
    /// in place).
    case summary([ClipboardContent.Representation])
}

/// Pure decision logic for which preview a `ClipboardContent` gets.
///
/// Extracted from the view controller so the priority rules are unit-testable
/// without views.
enum ClipboardPreviewPolicy {
    /// Text larger than this renders as `.summary` instead of the editor —
    /// `NSTextView` freezes the UI laying out multi-megabyte strings.
    static let maxEditableTextBytes = 2_000_000

    /// An image or inline rich-text representation up to this size is eagerly
    /// pulled (lazy mode) so the window shows a real preview rather than a chip;
    /// a larger payload stays a metadata placeholder until "Copy to Mac".
    ///
    /// A generous bound that covers typical screenshots/photos while capping a
    /// pathological auto-pull; tunable.
    static let maxEagerPreviewBytes = 32 * 1024 * 1024

    /// Chooses the preview for a buffer, in priority order.
    ///
    /// 1. A *file payload* (a representation tagged with a filename) shows as
    ///    the file itself — an image file as its image, any other file as a
    ///    file chip — before any inline-content rule, so a copied `.rtf` file
    ///    attaches as a file rather than rendering as rich text.
    /// 2. Inline content: an image beats a coexisting path/URL *descriptor*
    ///    text; then inline RTF renders styled; then plain text lands in the
    ///    editor; then a bare image; else a summary.
    /// A file-backed representation (no resident bytes) renders as a file chip
    /// rather than decoding an inline image preview — its bytes live on disk and
    /// stream on demand. (Rich previews rendered from offer metadata are a
    /// later, lazy-mode change.)
    static func mode(for content: ClipboardContent) -> ClipboardPreviewMode {
        if content.isEmpty {
            return .empty
        }
        if let file = content.filePayload {
            if let image = content.imageRepresentation, let data = image.inMemoryData {
                return .image(data: data, uti: image.uti)
            }
            return .file(filename: file.filename, uti: file.uti, byteCount: file.byteCount)
        }
        if let image = content.imageRepresentation, let data = image.inMemoryData,
            content.textIsPathOrURLOnly
        {
            return .image(data: data, uti: image.uti)
        }
        if let rich = content.richTextRepresentation, let data = rich.inMemoryData {
            return .richText(data: data, uti: rich.uti)
        }
        if let text = content.text, text.utf8.count <= maxEditableTextBytes {
            return .text(text)
        }
        if let image = content.imageRepresentation, let data = image.inMemoryData {
            return .image(data: data, uti: image.uti)
        }
        return .summary(content.representations)
    }
}
