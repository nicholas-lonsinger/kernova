import SwiftUI

/// Hover tooltip text shown on a missing-attachment icon.
///
/// Free-standing so both the settings view and the boot-order reorder
/// sheet show the same string.
let missingAttachmentTooltip =
    "Kernova can't find this file. It may have been moved, renamed, or its volume unmounted."

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
/// swaps in a red warning triangle with a tooltip when the file is
/// missing. Centralising the swap keeps the icon contract consistent
/// across `VMSettingsView`'s storage disk and removable media lists.
struct AttachmentIcon: View {
    let systemName: String
    /// Non-nil only when the file backing the row cannot be found.
    ///
    /// The string is shown as the hover tooltip on the warning icon.
    let missingTooltip: String?

    var body: some View {
        if let tooltip = missingTooltip {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                // RATIONALE: SF Symbols hit-test on their opaque pixels by
                // default, leaving the corners of a small triangle dead
                // for `.help`. Expand the hover region to the full
                // bounding rectangle so the tooltip is reliably reachable.
                .contentShape(Rectangle())
                .help(tooltip)
        } else {
            Image(systemName: systemName)
                .foregroundStyle(.secondary)
        }
    }
}
