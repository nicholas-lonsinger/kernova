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

    /// Chooses the preview for a buffer, in priority order.
    ///
    /// 1. A *file payload* (a representation tagged with a filename) shows as
    ///    the file itself — an image file as its image, any other file as a
    ///    file chip — before any inline-content rule, so a copied `.rtf` file
    ///    attaches as a file rather than rendering as rich text.
    /// 2. Inline content: an image beats a coexisting path/URL *descriptor*
    ///    text; then inline RTF renders styled; then plain text lands in the
    ///    editor; then a bare image; else a summary.
    static func mode(for content: ClipboardContent) -> ClipboardPreviewMode {
        if content.isEmpty {
            return .empty
        }
        if let file = content.filePayload {
            if let image = content.imageRepresentation {
                return .image(data: image.data, uti: image.uti)
            }
            return .file(filename: file.filename, uti: file.uti, byteCount: file.data.count)
        }
        if let image = content.imageRepresentation, content.textIsPathOrURLOnly {
            return .image(data: image.data, uti: image.uti)
        }
        if let rich = content.richTextRepresentation {
            return .richText(data: rich.data, uti: rich.uti)
        }
        if let text = content.text, text.utf8.count <= maxEditableTextBytes {
            return .text(text)
        }
        if let image = content.imageRepresentation {
            return .image(data: image.data, uti: image.uti)
        }
        return .summary(content.representations)
    }
}
