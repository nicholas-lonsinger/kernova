import AppKit

@testable import KernovaCore
@testable import KernovaUI

/// Whether the name in a sidebar row or header `cell` is open for renaming,
/// `nil` when `cell` shows no editable name.
@MainActor
func isRenaming(_ cell: NSView?) -> Bool? {
    cell.flatMap { firstSubview(InlineEditableLabel.self, in: $0)?.isEditing }
}
