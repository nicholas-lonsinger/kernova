import AppKit

/// Protocol the sidebar view controller implements to supply a per-row
/// context menu in response to a right-click.
@MainActor
protocol SidebarContextMenuProvider: AnyObject {
    /// Returns the menu to show for the row under `point`, or `nil` to
    /// suppress the menu.
    ///
    /// - Parameters:
    ///   - point: Local point inside the outline view where the click landed.
    ///   - row: The row index resolved from `point`. `-1` when the click
    ///     missed every row (in the empty area below the last row).
    /// - Returns: The contextual menu to display, or `nil` if no menu
    ///   should appear for this click location.
    func sidebarContextMenu(at point: NSPoint, row: Int) -> NSMenu?
}

/// `NSOutlineView` subclass that defers context-menu construction to the
/// owning view controller via ``SidebarContextMenuProvider``.
///
/// The base outline view supports a single static `menu` property, but the
/// sidebar's context menu varies by status (and by whether a row was hit at
/// all), so we override `menu(for event:)` to build the menu on demand.
@MainActor
final class SidebarOutlineView: NSOutlineView {
    weak var contextMenuProvider: (any SidebarContextMenuProvider)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // Update selection to match the right-clicked row before showing the
        // menu so the visual highlight reflects which VM the menu acts on.
        if row >= 0, selectedRow != row {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextMenuProvider?.sidebarContextMenu(at: point, row: row)
    }
}
