import AppKit
import SwiftUI

/// Caption-sized subtitle for an attachment row.
///
/// Prefixes a bold "Missing —" when the file backing the row can't be
/// found so the broken state is obvious without relying on a hover
/// tooltip (invisible to keyboard users, screen readers, and anyone
/// glancing at the list). Renders identically across `VMSettingsView`
/// and `StorageDiskReorderSheet`.
@ViewBuilder
func attachmentSubtitle(path: String, isMissing: Bool) -> some View {
    if isMissing {
        Text("\(Text("Missing — ").fontWeight(.semibold))\(path)")
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(1)
            .truncationMode(.middle)
    } else {
        Text(path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// Leading icon for an attachment row (storage disk, removable media).
///
/// Renders the normal SF Symbol when the backing file is present;
/// swaps in a red warning button with a hover tooltip and click-to-open
/// popover when the file is missing. The popover mirrors the affordance
/// pattern of [[InfoButton]]: brief hover label, full detail on click.
struct AttachmentIcon: View {
    let systemName: String
    /// Absolute path of the missing file, or `nil` when the file is
    /// present.
    ///
    /// When non-`nil`, the icon switches to a red-triangle `Button` that
    /// opens a popover containing the path (so the user can read it
    /// untruncated and copy it) and a short explanation.
    let missingPath: String?

    @State private var isPopoverPresented = false

    var body: some View {
        if let path = missingPath {
            Button {
                isPopoverPresented.toggle()
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("File missing")
            .accessibilityLabel("File missing — show details")
            .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
                MissingAttachmentPopover(path: path)
            }
        } else {
            Image(systemName: systemName)
                .foregroundStyle(.secondary)
        }
    }
}

/// Popover body shown when the user clicks a missing-attachment icon.
///
/// Pairs a labelled header with the full untruncated, selectable path and
/// a one-line explanation of the likely cause. Mirrors the visual rhythm
/// of `InfoButton`'s callout content.
private struct MissingAttachmentPopover: View {
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("File Missing")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Kernova can't find:")
                Text(Self.wrappingPath(path))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }

            Text("It may have been moved, renamed, or its volume unmounted.")
        }
        .font(.callout)
        .padding()
        .frame(width: 340)
    }

    /// Wraps a filesystem path so SwiftUI's `Text` will break it across
    /// multiple lines instead of truncating with an ellipsis.
    ///
    /// SwiftUI's default `byWordWrapping` only allows breaks at whitespace
    /// and a few punctuation characters, which leaves a deep path like
    /// `/Users/.../ubuntu-...-arm64 2.iso` as a single overlong line that
    /// gets cut. Attaching an `NSParagraphStyle` with `byCharWrapping`
    /// switches the layout engine to break at any glyph boundary, so the
    /// full path is always visible inside the popover's fixed-width frame.
    private static func wrappingPath(_ path: String) -> AttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        let ns = NSMutableAttributedString(string: path)
        ns.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: ns.length)
        )
        return AttributedString(ns)
    }
}
