import Foundation
import ImageIO
import KernovaProtocol
import UniformTypeIdentifiers

/// Pure string derivation for the clipboard window's content-type indicator and summary rows.
///
/// Extracted from the views so the formats are unit-testable.
enum ClipboardContentDescriber {
    /// Maximum per-representation rows in the summary view before the rest
    /// collapse into an "and N more" line.
    static let maxSummaryRows = 5

    /// One-line content-type indicator for the command bar, e.g.
    /// `"Empty"`, `"Plain text · 1.2 KB"`, `"PNG image · 1920 × 1080 · 3.4 MB"`,
    /// `"Rich Text Format + 2 more · 120 KB"`.
    static func indicatorText(for content: ClipboardContent) -> String {
        let primary: String
        switch ClipboardPreviewPolicy.mode(for: content) {
        case .empty:
            return "Empty"
        case .text:
            primary = "Plain text"
        case .richText(_, let uti):
            primary = displayName(forUTI: uti)
        case .image(let data, let uti):
            if let size = imagePixelSize(data: data) {
                primary = "\(displayName(forUTI: uti)) · \(Int(size.width)) × \(Int(size.height))"
            } else {
                primary = displayName(forUTI: uti)
            }
        case .file(let filename, let uti, _):
            // Name · type, e.g. "notes.txt · Plain Text Document" — the size is
            // appended below like every other mode.
            primary = "\(filename) · \(displayName(forUTI: uti))"
        case .summary(let representations):
            guard let first = representations.first else { return "Empty" }
            primary = displayName(forUTI: first.uti)
        }

        let size = DataFormatters.formatBytes(UInt64(content.totalByteCount))
        let extraCount = content.representations.count - 1
        if extraCount > 0 {
            return "\(primary) + \(extraCount) more · \(size)"
        }
        return "\(primary) · \(size)"
    }

    /// Per-representation lines for the summary view, capped at
    /// `maxSummaryRows` plus an "and N more" tail.
    static func summaryRows(for representations: [ClipboardContent.Representation]) -> [String] {
        var rows = representations.prefix(maxSummaryRows).map { representation in
            "\(displayName(forUTI: representation.uti)) — \(DataFormatters.formatBytes(UInt64(representation.byteCount)))"
        }
        let overflow = representations.count - maxSummaryRows
        if overflow > 0 {
            rows.append("and \(overflow) more")
        }
        return rows
    }

    /// Human-readable name for a UTI, falling back to the raw identifier for
    /// unregistered or dynamic types.
    static func displayName(forUTI uti: String) -> String {
        UTType(uti)?.localizedDescription ?? uti
    }

    /// Pixel dimensions read from the image header — no full decode.
    static func imagePixelSize(data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
