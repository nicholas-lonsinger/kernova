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
/// pattern of `InfoButton`: brief hover label, full detail on click.
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
        CalloutBody {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("File Missing")
                    .font(.headline)
            }

            Text("Kernova can't find:")

            WrappingPathLabel(path: path)

            Text("It may have been moved, renamed, or its volume unmounted.")
        }
    }
}

/// Selectable, monospaced path label that character-wraps long components.
///
/// SwiftUI's `Text` view ignores `NSParagraphStyle.lineBreakMode`, so the
/// only ways to wrap a path inside a fixed-width container in pure SwiftUI
/// are either to inject zero-width spaces into the string (which then get
/// included when the user copies the text — see review of PR #240) or to
/// truncate. Wrapping a real `NSTextField` configured with
/// `byCharWrapping` lets the AppKit layout engine break the string for
/// display without mutating it, so copy-to-clipboard yields the original
/// path verbatim.
private struct WrappingPathLabel: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: path)
        field.font = .monospacedSystemFont(
            ofSize: NSFont.systemFontSize - 1,
            weight: .regular
        )
        field.textColor = .secondaryLabelColor
        field.cell?.lineBreakMode = .byCharWrapping
        // Let SwiftUI's frame drive horizontal sizing; grow vertically as
        // the text wraps.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != path {
            field.stringValue = path
        }
    }
}
