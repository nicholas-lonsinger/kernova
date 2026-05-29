import AppKit
import os

/// A custom-drawn AppKit view that renders the `TerminalEmulator` cell grid.
///
/// Forwards keyboard input to the guest, and draws the visible grid directly
/// (no `NSTextView`): per-row, runs of cells
/// sharing the same rendition are painted in one shot. Owns its own scrollback
/// offset (scroll-wheel scrolls into history; output auto-follows only when
/// pinned to the bottom). Supports rubber-band selection + ⌘C copy and a
/// find-match highlight driven by the owning view controller.
///
/// The emulator is owned by `VMInstance` and outlives this view, so the view
/// attaches/detaches its `onRender` redraw hook as it enters/leaves a window.
@MainActor
final class TerminalView: NSView, NSMenuItemValidation {
    private static let logger = Logger(subsystem: "com.kernova.app", category: "TerminalView")

    private let emulator: TerminalEmulator

    /// Called with characters typed by the user, to send to the guest's serial input.
    var sendInput: ((String) -> Void)?

    /// Called with the grid dimensions whenever they change (for the status bar).
    var onGridSizeChange: ((Int, Int) -> Void)?

    // MARK: Fonts & metrics

    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private let cellWidth: CGFloat
    private let cellHeight: CGFloat

    // MARK: Scrollback / selection / find

    /// Lines scrolled up from the live bottom (0 = following live output).
    private var scrollOffset = 0
    private var lastScrollbackCount = 0

    private struct GridPoint: Equatable {
        var row: Int
        var col: Int
    }
    private var selectionAnchor: GridPoint?
    private var selectionHead: GridPoint?

    private struct FindHighlight: Equatable {
        var absoluteLine: Int
        var colStart: Int
        var colEnd: Int  // exclusive
    }
    private var findHighlight: FindHighlight?

    // MARK: Init

    init(emulator: TerminalEmulator) {
        self.emulator = emulator
        self.cellWidth = font.maximumAdvancement.width
        self.cellHeight = ceil(font.ascender - font.descender + font.leading)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = TerminalTheme.defaultBackground.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Serial console output")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: NSView overrides

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            emulator.onRender = { [weak self] in self?.scheduleRedraw() }
            lastScrollbackCount = emulator.scrollbackCount
            setAccessibilityValue(emulator.visibleText())
            needsDisplay = true
        } else {
            emulator.onRender = nil
        }
    }

    override func layout() {
        super.layout()
        updateGridSize()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateGridSize()
    }

    private func updateGridSize() {
        guard cellWidth > 0, cellHeight > 0, bounds.width > 0, bounds.height > 0 else { return }
        let cols = max(1, Int(bounds.width / cellWidth))
        let rows = max(1, Int(bounds.height / cellHeight))
        emulator.resize(cols: cols, rows: rows)
        onGridSizeChange?(emulator.cols, emulator.rows)
    }

    /// Re-anchors the scrollback view as new output arrives, then redraws.
    private func scheduleRedraw() {
        let scrollback = emulator.scrollbackCount
        if scrollOffset > 0 {
            // Keep the user pinned to the same history while output pushes lines up.
            let delta = scrollback - lastScrollbackCount
            if delta > 0 { scrollOffset += delta }
        }
        scrollOffset = min(scrollOffset, scrollback)
        lastScrollbackCount = scrollback
        setAccessibilityValue(emulator.visibleText())
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard cellWidth > 0, cellHeight > 0 else { return }
        TerminalTheme.defaultBackground.setFill()
        dirtyRect.fill()

        let rows = emulator.displayRows(scrollOffset: scrollOffset)
        let cols = emulator.cols
        let firstAbsolute = emulator.scrollbackCount - scrollOffset

        for r in 0..<rows.count {
            let y = CGFloat(r) * cellHeight
            guard y + cellHeight >= dirtyRect.minY, y <= dirtyRect.maxY else { continue }
            drawRow(rows[r], displayRow: r, absoluteLine: firstAbsolute + r, y: y, cols: cols)
        }

        drawCursorIfNeeded(rows)
    }

    private struct RunKey: Equatable {
        var foreground: TerminalColor
        var background: TerminalColor
        var attributes: CellAttributes
        var selected: Bool
        var found: Bool
    }

    private func drawRow(_ row: [TerminalCell], displayRow: Int, absoluteLine: Int, y: CGFloat, cols: Int) {
        var c = 0
        let count = min(cols, row.count)
        while c < count {
            let startCol = c
            let key = runKey(row[c], displayRow: displayRow, absoluteLine: absoluteLine, col: c)
            var scalars = String.UnicodeScalarView()
            while c < count, runKey(row[c], displayRow: displayRow, absoluteLine: absoluteLine, col: c) == key {
                scalars.append(row[c].scalar)
                c += 1
            }
            let rect = NSRect(
                x: CGFloat(startCol) * cellWidth, y: y,
                width: CGFloat(c - startCol) * cellWidth, height: cellHeight)
            drawRun(String(scalars), key: key, at: rect)
        }
    }

    private func runKey(_ cell: TerminalCell, displayRow: Int, absoluteLine: Int, col: Int) -> RunKey {
        RunKey(
            foreground: cell.foreground, background: cell.background, attributes: cell.attributes,
            selected: isSelected(row: displayRow, col: col),
            found: isFound(absoluteLine: absoluteLine, col: col))
    }

    private func drawRun(_ text: String, key: RunKey, at rect: NSRect) {
        let bold = key.attributes.contains(.bold)
        var fg = TerminalTheme.color(for: key.foreground, foreground: true, bold: bold)
        var bg = TerminalTheme.color(for: key.background, foreground: false, bold: false)
        if key.attributes.contains(.inverse) { swap(&fg, &bg) }
        if key.attributes.contains(.hidden) { fg = bg }
        if key.attributes.contains(.dim) { fg = fg.withAlphaComponent(0.6) }

        bg.setFill()
        rect.fill()
        if key.found {
            TerminalTheme.findHighlight.setFill()
            rect.fill()
        }
        if key.selected {
            TerminalTheme.selection.setFill()
            rect.fill()
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: bold ? boldFont : font,
            .foregroundColor: fg,
        ]
        if key.attributes.contains(.underline) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if key.attributes.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        NSAttributedString(string: text, attributes: attributes).draw(at: CGPoint(x: rect.minX, y: rect.minY))
    }

    private func drawCursorIfNeeded(_ rows: [[TerminalCell]]) {
        guard emulator.isCursorVisible, scrollOffset == 0 else { return }
        let r = emulator.cursorRow
        let c = emulator.cursorCol
        guard r >= 0, r < rows.count, c >= 0, c < emulator.cols else { return }
        let rect = NSRect(x: CGFloat(c) * cellWidth, y: CGFloat(r) * cellHeight, width: cellWidth, height: cellHeight)

        let focused = (window?.isKeyWindow ?? false) && (window?.firstResponder === self)
        if focused {
            TerminalTheme.cursor.setFill()
            rect.fill()
            // Redraw the glyph beneath the block in the background color for contrast.
            let scalar = c < rows[r].count ? rows[r][c].scalar : " "
            NSAttributedString(
                string: String(scalar),
                attributes: [.font: font, .foregroundColor: TerminalTheme.defaultBackground]
            ).draw(at: CGPoint(x: rect.minX, y: rect.minY))
        } else {
            TerminalTheme.cursor.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
    }

    // MARK: Selection

    private func normalizedSelection() -> (start: GridPoint, end: GridPoint)? {
        guard let a = selectionAnchor, let h = selectionHead else { return nil }
        if a.row < h.row || (a.row == h.row && a.col <= h.col) { return (a, h) }
        return (h, a)
    }

    private func isSelected(row: Int, col: Int) -> Bool {
        guard let (start, end) = normalizedSelection() else { return false }
        if row < start.row || row > end.row { return false }
        if row == start.row && col < start.col { return false }
        if row == end.row && col > end.col { return false }
        return true
    }

    private func gridPoint(for event: NSEvent) -> GridPoint {
        let p = convert(event.locationInWindow, from: nil)
        let col = max(0, min(emulator.cols - 1, Int(p.x / cellWidth)))
        let row = max(0, min(emulator.rows - 1, Int(p.y / cellHeight)))
        return GridPoint(row: row, col: col)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = gridPoint(for: event)
        selectionAnchor = point
        selectionHead = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        selectionHead = gridPoint(for: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        selectionHead = gridPoint(for: event)
        if selectionAnchor == selectionHead {
            // A plain click clears any selection.
            selectionAnchor = nil
            selectionHead = nil
        }
        needsDisplay = true
    }

    private func selectedText() -> String? {
        guard let (start, end) = normalizedSelection() else { return nil }
        let rows = emulator.displayRows(scrollOffset: scrollOffset)
        var lines: [String] = []
        for r in start.row...end.row where r < rows.count {
            let row = rows[r]
            let lo = (r == start.row) ? start.col : 0
            let hi = (r == end.row) ? end.col : emulator.cols - 1
            var scalars = String.UnicodeScalarView()
            for c in lo...min(hi, row.count - 1) { scalars.append(row[c].scalar) }
            var line = String(scalars)
            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Find (driven by the view controller)

    /// Returns the lines (scrollback + screen) to search over.
    func searchableLines() -> [String] { emulator.historyLines() }

    /// Highlights a match at the given absolute line/column span and scrolls it into view.
    func highlightMatch(absoluteLine: Int, colStart: Int, colEnd: Int) {
        findHighlight = FindHighlight(absoluteLine: absoluteLine, colStart: colStart, colEnd: colEnd)
        let scrollback = emulator.scrollbackCount
        scrollOffset = max(0, min(scrollback - absoluteLine, scrollback))
        needsDisplay = true
    }

    func clearFindHighlight() {
        findHighlight = nil
        needsDisplay = true
    }

    private func isFound(absoluteLine: Int, col: Int) -> Bool {
        guard let f = findHighlight else { return false }
        return f.absoluteLine == absoluteLine && col >= f.colStart && col < f.colEnd
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        let scrollback = emulator.scrollbackCount
        guard scrollback > 0 else { return }
        let lines = max(1, Int(abs(event.scrollingDeltaY) / cellHeight))
        if event.scrollingDeltaY > 0 {
            scrollOffset = min(scrollOffset + lines, scrollback)  // scroll up into history
        } else {
            scrollOffset = max(scrollOffset - lines, 0)
        }
        needsDisplay = true
    }

    // MARK: Keyboard input

    override func keyDown(with event: NSEvent) {
        guard let characters = event.characters, !characters.isEmpty else {
            super.keyDown(with: event)
            return
        }
        // Ignore arrow/function keys (Unicode private-use area) — input-side CSI
        // encoding is intentionally out of scope (issue #249 follow-up).
        if let first = characters.unicodeScalars.first, first.value >= 0xF700 {
            return
        }
        // Typing jumps back to the live bottom so the echo is visible.
        if scrollOffset != 0 {
            scrollOffset = 0
            needsDisplay = true
        }
        sendInput?(characters)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    // MARK: Menu actions

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc override func selectAll(_ sender: Any?) {
        let rows = emulator.displayRows(scrollOffset: scrollOffset)
        guard !rows.isEmpty else { return }
        selectionAnchor = GridPoint(row: 0, col: 0)
        selectionHead = GridPoint(row: rows.count - 1, col: emulator.cols - 1)
        needsDisplay = true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return normalizedSelection() != nil
        default:
            return true
        }
    }
}
