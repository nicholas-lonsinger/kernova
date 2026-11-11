import AppKit

@testable import KernovaCore
@testable import KernovaUI

/// The header `outline` shows for the section `id`, `nil` while it lists no
/// such section or has made no view for it.
@MainActor
func sectionHeader(_ id: SidebarSectionID, in outline: NSOutlineView) -> SidebarGroupHeaderCellView? {
    let row = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarSection)?.id == id }
    return row.flatMap { outline.view(atColumn: 0, row: $0, makeIfNecessary: false) as? SidebarGroupHeaderCellView }
}

/// The field editor of the rename open on `header`'s title, `nil` while none
/// is.
@MainActor
func renameEditor(of header: SidebarGroupHeaderCellView?) -> NSTextView? {
    header.flatMap { firstSubview(InlineEditableLabel.self, in: $0)?.currentEditor() as? NSTextView }
}

/// Types `text` over everything in `editor` and presses Return, as a user
/// naming something in place does.
@MainActor
func typeAndReturn(_ text: String, in editor: NSTextView) {
    editor.string = text
    editor.insertNewline(nil)
}
