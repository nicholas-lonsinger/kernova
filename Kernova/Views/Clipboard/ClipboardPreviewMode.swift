import Foundation
import KernovaProtocol

/// What the clipboard window's content area shows for a given buffer.
enum ClipboardPreviewMode: Equatable {
    /// No content — an empty, editable text view (typing must keep working).
    case empty
    /// Editable text editor.
    case text(String)
    /// Image preview decoded from `data`.
    case image(data: Data, uti: String)
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

    /// Priority: text wins over coexisting richer representations (the
    /// common RTF + plain-text copy lands in the editor; the command bar's
    /// indicator discloses the extras), then image, then summary.
    static func mode(for content: ClipboardContent) -> ClipboardPreviewMode {
        if content.isEmpty {
            return .empty
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
