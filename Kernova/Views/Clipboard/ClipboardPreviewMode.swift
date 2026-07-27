import Foundation
import KernovaKit

/// One file's metadata for the multi-file preview chip list (`.files`).
///
/// A named `Equatable` type rather than a tuple so `ClipboardPreviewMode` can
/// synthesize `Equatable` (tuples don't conform).
struct ClipboardFileEntry: Equatable {
    let filename: String
    let uti: String
    let byteCount: Int
}

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
    /// Image preview decoded straight from a file-backed image payload at `url`
    /// — a thumbnail read via ImageIO, without loading the whole file.
    case imageFile(url: URL, uti: String)
    /// A copied/dropped file shown as a chip (icon + name + type · size).
    case file(filename: String, uti: String, byteCount: Int)
    /// Several copied/dropped files shown as a list of chips with a count+size
    /// header.
    case files([ClipboardFileEntry])
    /// Non-editable per-representation summary (unknown formats, or text too
    /// large for `NSTextView`) — still sendable and copyable, just not edited
    /// in place.
    case summary([ClipboardContent.Representation])
    /// Confidential content (`org.nspasteboard.ConcealedType`): a read-only
    /// placeholder, never the secret bytes — the content still pastes into the
    /// peer, only its on-screen display is suppressed.
    case concealed
}

/// Pure decision logic for which preview a `ClipboardContent` gets.
enum ClipboardPreviewPolicy {
    /// Text larger than this renders as `.summary` instead of the editor —
    /// `NSTextView` freezes the UI laying out multi-megabyte strings.
    static let maxEditableTextBytes = 2_000_000

    /// An image or inline rich-text representation up to this size is eagerly
    /// pulled (lazy mode) so the window shows a real preview rather than a chip;
    /// a larger payload stays a metadata placeholder until "Copy to Mac".
    static let maxEagerPreviewBytes = 32 * 1024 * 1024

    /// Chooses the preview for a buffer, in priority order.
    ///
    /// Concealed content short-circuits ahead of every other rule — the window
    /// never renders the secret bytes, whatever representation carries them.
    /// Then several file payloads; then a single file payload (an image file as
    /// its image, anything else as a chip) ahead of any inline-content rule, so a
    /// copied `.rtf` file attaches as a file rather than rendering as rich text.
    static func mode(for content: ClipboardContent) -> ClipboardPreviewMode {
        if content.isEmpty {
            return .empty
        }
        if content.isConcealed {
            return .concealed
        }
        let files = content.filePayloads
        if files.count > 1 {
            return .files(
                files.map {
                    ClipboardFileEntry(filename: $0.filename, uti: $0.uti, byteCount: $0.byteCount)
                })
        }
        if let file = files.first {
            if let image = content.imageRepresentation {
                if let data = image.inMemoryData {
                    return .image(data: data, uti: image.uti)
                }
                if let url = image.fileURL {
                    return .imageFile(url: url, uti: image.uti)
                }
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
