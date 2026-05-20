import SwiftUI

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
                .help(tooltip)
        } else {
            Image(systemName: systemName)
                .foregroundStyle(.secondary)
        }
    }
}
