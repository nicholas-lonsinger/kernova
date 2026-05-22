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
/// SwiftUI shim around the AppKit ``AttachmentIconButton``: renders the
/// normal SF Symbol when the backing file is present, swaps in a red
/// warning button with a real `NSPopover` showing the full untruncated
/// path when the file is missing.
///
/// The shim exists so SwiftUI call sites (`VMSettingsView`,
/// `StorageDiskReorderSheet`) keep the same `AttachmentIcon(systemName:missingPath:)`
/// initializer surface during the incremental SwiftUI→AppKit transition.
struct AttachmentIcon: NSViewRepresentable {
    let systemName: String
    /// Absolute path of the missing file, or `nil` when the file is present.
    ///
    /// When non-`nil`, the icon switches to a red-triangle button that opens
    /// a popover containing the path and a short explanation.
    let missingPath: String?

    func makeNSView(context: Context) -> AttachmentIconButton {
        let button = AttachmentIconButton()
        button.configure(systemName: systemName, missingPath: missingPath)
        return button
    }

    func updateNSView(_ button: AttachmentIconButton, context: Context) {
        button.configure(systemName: systemName, missingPath: missingPath)
    }
}
