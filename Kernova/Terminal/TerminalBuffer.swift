import Foundation

/// A fixed-size grid of `TerminalCell`s — one screen buffer.
///
/// Stored as an array-of-arrays (`rows`) rather than a flat array: the hottest
/// structural operations in a terminal are full-row scrolls and line
/// insert/delete, which are O(rows) pointer moves here (`remove`/`insert`) but
/// would require an O(cells) `memmove` with a flat backing store. Cell writes
/// stay O(1).
///
/// The buffer is cursor-agnostic — all operations take explicit coordinates and
/// regions. The cursor, scroll margins, and tab stops are owned by
/// `TerminalEmulator`, which also owns the (primary-only) scrollback.
struct TerminalBuffer: Sendable {
    private(set) var rows: [[TerminalCell]]
    private(set) var cols: Int
    private(set) var rowCount: Int

    init(cols: Int, rows: Int) {
        let c = max(1, cols)
        let r = max(1, rows)
        self.cols = c
        self.rowCount = r
        self.rows = Array(repeating: Self.blankRow(cols: c), count: r)
    }

    static func blankRow(cols: Int) -> [TerminalCell] {
        Array(repeating: .blank, count: max(1, cols))
    }

    private var blankRow: [TerminalCell] { Self.blankRow(cols: cols) }

    // MARK: - Cell access

    func cell(row: Int, col: Int) -> TerminalCell {
        guard row >= 0, row < rowCount, col >= 0, col < cols else { return .blank }
        return rows[row][col]
    }

    mutating func setCell(_ cell: TerminalCell, row: Int, col: Int) {
        guard row >= 0, row < rowCount, col >= 0, col < cols else { return }
        rows[row][col] = cell
    }

    /// Replaces every cell with `fill`.
    mutating func clear(with fill: TerminalCell = .blank) {
        rows = Array(repeating: Array(repeating: fill, count: cols), count: rowCount)
    }

    // MARK: - Scrolling

    /// Scrolls the inclusive region `[top, bottom]` up by `count` lines, filling
    /// vacated lines at the bottom with `fill`.
    ///
    /// Returns the lines pushed off the top (so the caller can route them to
    /// scrollback).
    @discardableResult
    mutating func scrollUp(top: Int, bottom: Int, count: Int = 1, fill: TerminalCell = .blank)
        -> [[TerminalCell]]
    {
        let top = max(0, top)
        let bottom = min(rowCount - 1, bottom)
        guard top <= bottom else { return [] }
        let n = min(count, bottom - top + 1)
        var removed: [[TerminalCell]] = []
        removed.reserveCapacity(n)
        let fillRow = Array(repeating: fill, count: cols)
        for _ in 0..<n {
            removed.append(rows[top])
            rows.remove(at: top)
            rows.insert(fillRow, at: bottom)
        }
        return removed
    }

    /// Scrolls the inclusive region `[top, bottom]` down by `count` lines,
    /// filling vacated lines at the top with `fill`.
    mutating func scrollDown(top: Int, bottom: Int, count: Int = 1, fill: TerminalCell = .blank) {
        let top = max(0, top)
        let bottom = min(rowCount - 1, bottom)
        guard top <= bottom else { return }
        let n = min(count, bottom - top + 1)
        let fillRow = Array(repeating: fill, count: cols)
        for _ in 0..<n {
            rows.remove(at: bottom)
            rows.insert(fillRow, at: top)
        }
    }

    // MARK: - Erase

    /// Erases columns `from...through` (inclusive) of `row` with `fill`.
    mutating func eraseInRow(_ row: Int, from: Int, through: Int, fill: TerminalCell = .blank) {
        guard row >= 0, row < rowCount else { return }
        let lo = max(0, from)
        let hi = min(cols - 1, through)
        guard lo <= hi else { return }
        for col in lo...hi { rows[row][col] = fill }
    }

    /// Replaces whole rows `from...through` (inclusive) with blank lines of `fill`.
    mutating func eraseRows(from: Int, through: Int, fill: TerminalCell = .blank) {
        let lo = max(0, from)
        let hi = min(rowCount - 1, through)
        guard lo <= hi else { return }
        let fillRow = Array(repeating: fill, count: cols)
        for row in lo...hi { rows[row] = fillRow }
    }

    // MARK: - Line / character insert & delete (within the scroll region)

    /// Inserts `count` blank lines at `row`, pushing lines below down within
    /// `[row, bottom]`.
    ///
    /// Lines pushed past `bottom` are lost.
    mutating func insertLines(at row: Int, count: Int, bottom: Int, fill: TerminalCell = .blank) {
        let bottom = min(rowCount - 1, bottom)
        guard row >= 0, row <= bottom else { return }
        let n = min(count, bottom - row + 1)
        let fillRow = Array(repeating: fill, count: cols)
        for _ in 0..<n {
            rows.remove(at: bottom)
            rows.insert(fillRow, at: row)
        }
    }

    /// Deletes `count` lines at `row`, pulling lines below up within
    /// `[row, bottom]` and filling the bottom with blanks.
    mutating func deleteLines(at row: Int, count: Int, bottom: Int, fill: TerminalCell = .blank) {
        let bottom = min(rowCount - 1, bottom)
        guard row >= 0, row <= bottom else { return }
        let n = min(count, bottom - row + 1)
        let fillRow = Array(repeating: fill, count: cols)
        for _ in 0..<n {
            rows.remove(at: row)
            rows.insert(fillRow, at: bottom)
        }
    }

    /// Inserts `count` blank cells at `(row, col)`, shifting the rest of the line right.
    mutating func insertChars(row: Int, col: Int, count: Int, fill: TerminalCell = .blank) {
        guard row >= 0, row < rowCount, col >= 0, col < cols else { return }
        let n = min(count, cols - col)
        for _ in 0..<n {
            rows[row].removeLast()
            rows[row].insert(fill, at: col)
        }
    }

    /// Deletes `count` cells at `(row, col)`, shifting the rest of the line left
    /// and filling the tail with blanks.
    mutating func deleteChars(row: Int, col: Int, count: Int, fill: TerminalCell = .blank) {
        guard row >= 0, row < rowCount, col >= 0, col < cols else { return }
        let n = min(count, cols - col)
        for _ in 0..<n {
            rows[row].remove(at: col)
            rows[row].append(fill)
        }
    }

    // MARK: - Resize

    /// Resizes to `newCols × newRows`.
    ///
    /// Existing content is preserved top-aligned; rows are truncated/padded to
    /// the new width, rows are dropped from the bottom or appended as blanks. No
    /// reflow (matches xterm's default).
    mutating func resize(cols newCols: Int, rows newRows: Int, fill: TerminalCell = .blank) {
        let nc = max(1, newCols)
        let nr = max(1, newRows)

        if nc != cols {
            for r in 0..<rows.count {
                if rows[r].count > nc {
                    rows[r].removeLast(rows[r].count - nc)
                } else if rows[r].count < nc {
                    rows[r].append(contentsOf: Array(repeating: fill, count: nc - rows[r].count))
                }
            }
            cols = nc
        }

        if nr > rowCount {
            rows.append(contentsOf: Array(repeating: Array(repeating: fill, count: nc), count: nr - rowCount))
        } else if nr < rowCount {
            rows.removeLast(rowCount - nr)
        }
        rowCount = nr
    }
}
