import AppKit

/// The clicks that start an in-place rename of a table row's name: a slow
/// second click — a click on the name of the row that was already selected —
/// and, where the table offers it, a double-click.
///
/// The table hands every mouse-down here from its `mouseDown(with:)` override,
/// with its own tracking of the press. The name's ``InlineEditableLabel`` uses
/// ``InlineEditableLabel/ClickHandling/delegatedToEnclosingView``, so the clicks
/// reach the table.
///
/// A slow second click waits out the double-click interval, so a double-click
/// takes over instead, and renames the row's item — captured by identity, so
/// a list change during the wait can't retarget it — only while that item's
/// row is still the selected one.
@MainActor
final class InPlaceRenameClicks<Item> {
    /// Runs `fire` once the double-click interval has passed, unless the
    /// returned cancel runs first.
    typealias Deferral = @MainActor (_ fire: @escaping @MainActor () -> Void) -> @MainActor () -> Void

    /// Opens the rename on a row.
    var begin: ((Int) -> Void)?

    private unowned let table: NSTableView
    /// Whether a double-click on a row opens its rename; otherwise it only
    /// drops a pending one, and the table's `doubleAction` has it.
    private let doubleClickBegins: Bool
    private let deferral: Deferral
    /// What a row holds now, `nil` for nothing renameable.
    private let item: (Int) -> Item?
    /// The row holding an item now, `nil` once none does.
    private let row: (Item) -> Int?
    /// Whether a point in the table is over a row's name.
    private let isOverName: (NSPoint, Int) -> Bool

    /// Cancels the rename a slow second click armed, while it waits out the
    /// double-click interval.
    private var cancelPending: (@MainActor () -> Void)?

    init(
        table: NSTableView, doubleClickBegins: Bool, deferral: @escaping Deferral = afterDoubleClickInterval,
        item: @escaping (Int) -> Item?, row: @escaping (Item) -> Int?,
        isOverName: @escaping (NSPoint, Int) -> Bool
    ) {
        self.table = table
        self.doubleClickBegins = doubleClickBegins
        self.deferral = deferral
        self.item = item
        self.row = row
        self.isOverName = isOverName
    }

    /// Handles a mouse-down on the table.
    ///
    /// `tracking` is the table's own handling of the press — selection and
    /// drag tracking, its `super.mouseDown(with:)` — returning once the press
    /// is released, with where in the window the pointer then was.
    func mouseDown(with event: NSEvent, tracking: (NSEvent) -> NSPoint) {
        let start = event.locationInWindow
        let clickedRow = table.row(at: table.convert(start, from: nil))

        if event.clickCount >= 2 {
            cancel()
            let end = tracking(event)
            if doubleClickBegins, clickedRow >= 0, Self.releasedInPlace(start, end) { begin?(clickedRow) }
            return
        }

        // Read before the press changes the selection: renaming takes a click
        // on the row that was already selected.
        let wasSelected = clickedRow >= 0 && table.selectedRow == clickedRow
        let overName = clickedRow >= 0 && isOverName(table.convert(start, from: nil), clickedRow)

        let end = tracking(event)

        guard wasSelected, overName, Self.releasedInPlace(start, end), table.selectedRow == clickedRow,
            let clickedItem = item(clickedRow)
        else { return }
        cancel()
        cancelPending = deferral { [weak self] in self?.firePendingRename(of: clickedItem) }
    }

    /// Drops a pending slow-second-click rename, so it can't fire later.
    func cancel() {
        cancelPending?()
        cancelPending = nil
    }

    private func firePendingRename(of item: Item) {
        cancelPending = nil
        guard let current = row(item), current == table.selectedRow else { return }
        begin?(current)
    }

    /// Whether a press released at `end` stayed a click rather than becoming
    /// a drag, both in window coordinates.
    private static func releasedInPlace(_ start: NSPoint, _ end: NSPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) <= 4
    }
}

/// Runs `fire` once the user's double-click interval has passed, in the run
/// loop's default mode, so not while a press is being tracked.
@MainActor
func afterDoubleClickInterval(_ fire: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
    let timer = Timer(timeInterval: NSEvent.doubleClickInterval, repeats: false) { _ in
        MainActor.assumeIsolated { fire() }
    }
    RunLoop.main.add(timer, forMode: .default)
    return { timer.invalidate() }
}
