import Foundation
import os

/// A hand-rolled VT100/xterm-subset terminal emulator.
///
/// Drives a `VTParser` over the raw guest byte stream and applies the decoded
/// events to an in-memory cell grid: cursor motion, SGR rendition, erase/scroll,
/// scroll regions, alt-screen, and scrollback. Replies to the guest's cursor
/// and device-attribute probes through `respond` so serial getty terminal
/// detection works. The render layer reads the grid and redraws on `onRender`.
///
/// `@MainActor`: fed from the main-actor drain in `VMInstance` and read by the
/// AppKit render view; never touched off the main actor. AppKit-free by design.
///
/// Known v1 limitations: wide (CJK/emoji) glyphs are treated as single-cell;
/// truecolor is preserved but the palette render may quantize; no mouse
/// reporting, Sixel, or cursor blink.
@MainActor
final class TerminalEmulator: TerminalPerformer {
    private static let logger = Logger(subsystem: "com.kernova.app", category: "TerminalEmulator")

    /// Maximum scrollback lines retained for the primary screen.
    static let maxScrollbackRows = 5000
    /// Trim scrollback in batches once the cap is exceeded (amortizes `removeFirst`).
    private static let scrollbackTrimBatch = 256
    /// Clamp for grid dimensions (defends against absurd window sizes).
    private static let maxDimension = 1000

    // MARK: Output hooks

    /// Sends a reply (DSR cursor report, device attributes) back to the guest.
    ///
    /// Wired by `VMInstance` so probes are answered even with the console window closed.
    var respond: ((String) -> Void)?
    /// Called once after each `feed`/`resize`/`reset` that may have changed the visible grid.
    ///
    /// Set by the render view (and cleared on teardown).
    var onRender: (() -> Void)?
    /// The most recent window/icon title set via OSC 0/1/2.
    private(set) var title: String = ""

    // MARK: Grid state

    private(set) var cols: Int
    private(set) var rows: Int
    private var buffers: [TerminalBuffer]
    private var activeIndex = 0  // 0 = primary, 1 = alternate
    private var scrollback: [[TerminalCell]] = []

    private(set) var cursorRow = 0
    private(set) var cursorCol = 0
    private var pendingWrap = false

    private var scrollTop = 0
    private var scrollBottom: Int
    private var tabStops: Set<Int> = []

    // MARK: Rendition / modes

    private struct Pen {
        var foreground: TerminalColor = .default
        var background: TerminalColor = .default
        var attributes: CellAttributes = []
    }
    private var pen = Pen()

    private struct SavedCursor {
        var row: Int
        var col: Int
        var pen: Pen
        var originMode: Bool
        var g0Graphics: Bool
        var g1Graphics: Bool
        var glSelectsG1: Bool
    }
    private var savedCursor: SavedCursor?

    private var autowrap = true
    private(set) var isCursorVisible = true
    private var originMode = false
    private var insertMode = false
    private var lineFeedNewLineMode = false
    /// Stored only; honored by the (out-of-scope) input encoder later.
    private(set) var applicationCursorKeys = false
    private(set) var bracketedPaste = false

    // Charsets: G0/G1 each ASCII or DEC special graphics; GL selects one of them.
    private var g0Graphics = false
    private var g1Graphics = false
    private var glSelectsG1 = false
    /// `true` when the charset currently mapped into GL is DEC special graphics.
    private var glGraphics: Bool { glSelectsG1 ? g1Graphics : g0Graphics }

    private var parser = VTParser()

    // MARK: Init

    init(cols: Int = 80, rows: Int = 24) {
        let c = min(max(1, cols), Self.maxDimension)
        let r = min(max(1, rows), Self.maxDimension)
        self.cols = c
        self.rows = r
        self.scrollBottom = r - 1
        self.buffers = [TerminalBuffer(cols: c, rows: r), TerminalBuffer(cols: c, rows: r)]
        resetTabStops()
    }

    // MARK: Public API

    /// Feeds raw guest bytes, firing `onRender` once afterward.
    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        parser.feed(data, to: self)
        onRender?()
    }

    /// Full reset of contents (RIS-equivalent) while preserving the grid size.
    ///
    /// Called at serial-session start and teardown so a restarted VM shows no
    /// stale output.
    func reset() {
        buffers[0].clear()
        buffers[1].clear()
        scrollback.removeAll(keepingCapacity: false)
        activeIndex = 0
        cursorRow = 0
        cursorCol = 0
        pendingWrap = false
        scrollTop = 0
        scrollBottom = rows - 1
        pen = Pen()
        savedCursor = nil
        autowrap = true
        isCursorVisible = true
        originMode = false
        insertMode = false
        lineFeedNewLineMode = false
        applicationCursorKeys = false
        bracketedPaste = false
        g0Graphics = false
        g1Graphics = false
        glSelectsG1 = false
        title = ""
        resetTabStops()
        Self.logger.notice("Terminal emulator reset (\(self.cols, privacy: .public)×\(self.rows, privacy: .public))")
        onRender?()
    }

    /// Resizes the grid from the render view's font metrics (no scrollback reflow).
    func resize(cols newCols: Int, rows newRows: Int) {
        let nc = min(max(1, newCols), Self.maxDimension)
        let nr = min(max(1, newRows), Self.maxDimension)
        guard nc != cols || nr != rows else { return }

        buffers[0].resize(cols: nc, rows: nr)
        buffers[1].resize(cols: nc, rows: nr)
        cols = nc
        rows = nr

        // Clamp cursor and margins into the new bounds.
        cursorRow = min(cursorRow, nr - 1)
        cursorCol = min(cursorCol, nc - 1)
        pendingWrap = false
        scrollTop = min(scrollTop, nr - 1)
        scrollBottom = min(scrollBottom, nr - 1)
        if scrollTop >= scrollBottom {
            scrollTop = 0
            scrollBottom = nr - 1
        }
        resetTabStops()
        onRender?()
    }

    // MARK: Render reads

    /// Number of scrollback lines available above the live screen (primary only).
    var scrollbackCount: Int { activeIndex == 0 ? scrollback.count : 0 }

    /// The `rows` lines to display for a given scrollback offset (0 = live screen,
    /// up to `scrollbackCount` = oldest history at top).
    ///
    /// O(rows) — indexes rather than concatenating the whole history.
    func displayRows(scrollOffset: Int) -> [[TerminalCell]] {
        let active = buffers[activeIndex].rows
        guard activeIndex == 0, !scrollback.isEmpty else { return active }

        let offset = max(0, min(scrollOffset, scrollback.count))
        guard offset > 0 else { return active }

        let total = scrollback.count + rows
        let start = total - rows - offset
        var result: [[TerminalCell]] = []
        result.reserveCapacity(rows)
        for i in 0..<rows {
            let index = start + i
            if index < scrollback.count {
                result.append(scrollback[index])
            } else {
                result.append(active[index - scrollback.count])
            }
        }
        return result
    }

    /// The visible live screen serialized to text (for accessibility), trailing blanks trimmed.
    func visibleText() -> String {
        rowsToText(buffers[activeIndex].rows)
    }

    /// Scrollback + live screen serialized to text (for find), trailing blanks trimmed.
    func fullText() -> String {
        historyLines().joined(separator: "\n")
    }

    /// Scrollback + live screen as one trimmed string per line (for find).
    ///
    /// The last `rows` entries are the live screen; earlier entries are scrollback.
    func historyLines() -> [String] {
        (scrollback + buffers[activeIndex].rows).map(Self.trimmedLine)
    }

    private func rowsToText(_ rows: [[TerminalCell]]) -> String {
        rows.map(Self.trimmedLine).joined(separator: "\n")
    }

    private static func trimmedLine(_ row: [TerminalCell]) -> String {
        var line = String(String.UnicodeScalarView(row.map { $0.scalar }))
        while line.hasSuffix(" ") { line.removeLast() }
        return line
    }

    // MARK: - TerminalPerformer

    func print(_ scalar: UnicodeScalar) {
        if pendingWrap && autowrap {
            cursorCol = 0
            lineFeed()
            pendingWrap = false
        }

        let glyph = glGraphics ? Self.decGraphics(scalar) : scalar
        if insertMode {
            buffers[activeIndex].insertChars(row: cursorRow, col: cursorCol, count: 1, fill: eraseCell)
        }
        let cell = TerminalCell(
            scalar: glyph, foreground: pen.foreground, background: pen.background,
            attributes: pen.attributes)
        buffers[activeIndex].setCell(cell, row: cursorRow, col: cursorCol)

        if cursorCol >= cols - 1 {
            if autowrap { pendingWrap = true }
        } else {
            cursorCol += 1
        }
    }

    func execute(_ control: UInt8) {
        switch control {
        case 0x07:  // BEL — no audible bell
            break
        case 0x08:  // BS
            if cursorCol > 0 { cursorCol -= 1 }
            pendingWrap = false
        case 0x09:  // HT
            cursorCol = nextTabStop(after: cursorCol)
            pendingWrap = false
        case 0x0A, 0x0B, 0x0C:  // LF, VT, FF
            lineFeed()
            if lineFeedNewLineMode { cursorCol = 0 }
            pendingWrap = false
        case 0x0D:  // CR
            cursorCol = 0
            pendingWrap = false
        case 0x0E:  // SO — select G1 into GL
            glSelectsG1 = true
        case 0x0F:  // SI — select G0 into GL
            glSelectsG1 = false
        default:
            break
        }
    }

    func escDispatch(intermediates: [UInt8], final: UInt8) {
        if intermediates.isEmpty {
            switch final {
            case 0x63:  // c — RIS full reset
                reset()
            case 0x44:  // D — IND (index)
                lineFeed()
                pendingWrap = false
            case 0x45:  // E — NEL (next line)
                cursorCol = 0
                lineFeed()
                pendingWrap = false
            case 0x4D:  // M — RI (reverse index)
                reverseIndex()
                pendingWrap = false
            case 0x37:  // 7 — DECSC
                saveCursor()
            case 0x38:  // 8 — DECRC
                restoreCursor()
            case 0x48:  // H — HTS (set tab stop)
                tabStops.insert(cursorCol)
            case 0x3D, 0x3E:  // = DECKPAM / > DECKPNM — keypad mode (no-op)
                break
            default:
                break
            }
            return
        }

        // Charset designation: ESC ( / ) / * / + <final>
        if intermediates.count == 1 {
            let graphics = (final == 0x30)  // '0' = DEC special graphics; else ASCII-ish
            switch intermediates[0] {
            case 0x28:  // ( — G0
                g0Graphics = graphics
            case 0x29:  // ) — G1
                g1Graphics = graphics
            default:  // * (G2), + (G3) — accepted but unused
                break
            }
        }
    }

    func csiDispatch(prefix: UInt8?, params: [Int], intermediates: [UInt8], final: UInt8) {
        // DECSTR soft reset: CSI ! p
        if intermediates == [0x21], final == 0x70 {
            softReset()
            return
        }

        if prefix == 0x3F {  // '?' — DEC private modes
            switch final {
            case 0x68:  // h — set
                setPrivateModes(params, enabled: true)
            case 0x6C:  // l — reset
                setPrivateModes(params, enabled: false)
            default:
                break
            }
            return
        }

        // '>' secondary device attributes
        if prefix == 0x3E, final == 0x63 {
            respond?("\u{1B}[>0;0;0c")
            return
        }
        // Other private-prefixed sequences: ignore.
        guard prefix == nil else { return }

        switch final {
        case 0x41:  // A — CUU
            cursorUp(arg(params, 0, 1))
        case 0x42:  // B — CUD
            cursorDown(arg(params, 0, 1))
        case 0x43:  // C — CUF
            cursorForward(arg(params, 0, 1))
        case 0x44:  // D — CUB
            cursorBack(arg(params, 0, 1))
        case 0x45:  // E — CNL
            cursorCol = 0
            cursorDown(arg(params, 0, 1))
        case 0x46:  // F — CPL
            cursorCol = 0
            cursorUp(arg(params, 0, 1))
        case 0x47, 0x60:  // G / ` — CHA / HPA
            setCursor(row: cursorRow, col: arg(params, 0, 1) - 1)
        case 0x64:  // d — VPA
            setCursorRowAbsolute(arg(params, 0, 1) - 1)
        case 0x48, 0x66:  // H / f — CUP / HVP
            let r = arg(params, 0, 1) - 1
            let c = arg(params, 1, 1) - 1
            setCursorPosition(row: r, col: c)
        case 0x4A:  // J — ED
            eraseInDisplay(arg(params, 0, 0))
        case 0x4B:  // K — EL
            eraseInLine(arg(params, 0, 0))
        case 0x4C:  // L — IL
            buffers[activeIndex].insertLines(
                at: cursorRow, count: arg(params, 0, 1), bottom: scrollBottom, fill: eraseCell)
        case 0x4D:  // M — DL
            buffers[activeIndex].deleteLines(
                at: cursorRow, count: arg(params, 0, 1), bottom: scrollBottom, fill: eraseCell)
        case 0x40:  // @ — ICH
            buffers[activeIndex].insertChars(
                row: cursorRow, col: cursorCol, count: arg(params, 0, 1), fill: eraseCell)
        case 0x50:  // P — DCH
            buffers[activeIndex].deleteChars(
                row: cursorRow, col: cursorCol, count: arg(params, 0, 1), fill: eraseCell)
        case 0x58:  // X — ECH
            let n = arg(params, 0, 1)
            buffers[activeIndex].eraseInRow(
                cursorRow, from: cursorCol, through: cursorCol + n - 1, fill: eraseCell)
        case 0x53:  // S — SU
            scrollRegionUp(arg(params, 0, 1))
        case 0x54:  // T — SD
            buffers[activeIndex].scrollDown(
                top: scrollTop, bottom: scrollBottom, count: arg(params, 0, 1), fill: eraseCell)
        case 0x72:  // r — DECSTBM
            setScrollRegion(top: arg(params, 0, 1), bottom: arg(params, 1, rows))
        case 0x6D:  // m — SGR
            applySGR(params)
        case 0x6E:  // n — DSR
            deviceStatusReport(arg(params, 0, 0))
        case 0x63:  // c — primary DA
            respond?("\u{1B}[?6c")
        case 0x67:  // g — TBC (tab clear)
            if arg(params, 0, 0) == 3 { tabStops.removeAll() } else { tabStops.remove(cursorCol) }
        case 0x68:  // h — SM (ANSI modes)
            setAnsiModes(params, enabled: true)
        case 0x6C:  // l — RM
            setAnsiModes(params, enabled: false)
        case 0x73:  // s — save cursor (ANSI.SYS)
            saveCursor()
        case 0x75:  // u — restore cursor
            restoreCursor()
        default:
            break
        }
    }

    func oscDispatch(_ data: [UInt8]) {
        guard let string = String(bytes: data, encoding: .utf8) else { return }
        // Split "code;payload".
        guard let sep = string.firstIndex(of: ";") else {
            // Bare command (e.g. "104" reset palette) — no-op.
            return
        }
        let code = String(string[string.startIndex..<sep])
        let payload = String(string[string.index(after: sep)...])
        switch code {
        case "0", "1", "2":  // window / icon title
            title = payload
        default:
            break  // palette / clipboard / hyperlink OSCs — ignored in v1
        }
    }

    // MARK: - Cursor motion

    private func clamp(_ value: Int, _ lo: Int, _ hi: Int) -> Int { min(max(value, lo), hi) }

    private func cursorUp(_ n: Int) {
        let limit = cursorRow >= scrollTop ? scrollTop : 0
        cursorRow = max(limit, cursorRow - max(1, n))
        pendingWrap = false
    }

    private func cursorDown(_ n: Int) {
        let limit = cursorRow <= scrollBottom ? scrollBottom : rows - 1
        cursorRow = min(limit, cursorRow + max(1, n))
        pendingWrap = false
    }

    private func cursorForward(_ n: Int) {
        cursorCol = min(cols - 1, cursorCol + max(1, n))
        pendingWrap = false
    }

    private func cursorBack(_ n: Int) {
        cursorCol = max(0, cursorCol - max(1, n))
        pendingWrap = false
    }

    private func setCursor(row: Int, col: Int) {
        cursorRow = clamp(row, 0, rows - 1)
        cursorCol = clamp(col, 0, cols - 1)
        pendingWrap = false
    }

    private func setCursorRowAbsolute(_ row: Int) {
        if originMode {
            cursorRow = clamp(scrollTop + row, scrollTop, scrollBottom)
        } else {
            cursorRow = clamp(row, 0, rows - 1)
        }
        pendingWrap = false
    }

    private func setCursorPosition(row: Int, col: Int) {
        if originMode {
            cursorRow = clamp(scrollTop + row, scrollTop, scrollBottom)
        } else {
            cursorRow = clamp(row, 0, rows - 1)
        }
        cursorCol = clamp(col, 0, cols - 1)
        pendingWrap = false
    }

    private func lineFeed() {
        if cursorRow == scrollBottom {
            let removed = buffers[activeIndex].scrollUp(
                top: scrollTop, bottom: scrollBottom, count: 1, fill: eraseCell)
            if activeIndex == 0 && scrollTop == 0 {
                appendScrollback(removed)
            }
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private func reverseIndex() {
        if cursorRow == scrollTop {
            buffers[activeIndex].scrollDown(
                top: scrollTop, bottom: scrollBottom, count: 1, fill: eraseCell)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    private func scrollRegionUp(_ n: Int) {
        let removed = buffers[activeIndex].scrollUp(
            top: scrollTop, bottom: scrollBottom, count: max(1, n), fill: eraseCell)
        if activeIndex == 0 && scrollTop == 0 {
            appendScrollback(removed)
        }
    }

    // MARK: - Erase

    private func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:  // cursor to end
            buffers[activeIndex].eraseInRow(cursorRow, from: cursorCol, through: cols - 1, fill: eraseCell)
            if cursorRow + 1 <= rows - 1 {
                buffers[activeIndex].eraseRows(from: cursorRow + 1, through: rows - 1, fill: eraseCell)
            }
        case 1:  // start to cursor
            if cursorRow - 1 >= 0 {
                buffers[activeIndex].eraseRows(from: 0, through: cursorRow - 1, fill: eraseCell)
            }
            buffers[activeIndex].eraseInRow(cursorRow, from: 0, through: cursorCol, fill: eraseCell)
        case 3:  // whole screen + scrollback
            buffers[activeIndex].eraseRows(from: 0, through: rows - 1, fill: eraseCell)
            scrollback.removeAll(keepingCapacity: false)
        default:  // 2 — whole screen
            buffers[activeIndex].eraseRows(from: 0, through: rows - 1, fill: eraseCell)
        }
    }

    private func eraseInLine(_ mode: Int) {
        switch mode {
        case 1:  // start to cursor
            buffers[activeIndex].eraseInRow(cursorRow, from: 0, through: cursorCol, fill: eraseCell)
        case 2:  // whole line
            buffers[activeIndex].eraseInRow(cursorRow, from: 0, through: cols - 1, fill: eraseCell)
        default:  // 0 — cursor to end
            buffers[activeIndex].eraseInRow(cursorRow, from: cursorCol, through: cols - 1, fill: eraseCell)
        }
    }

    // MARK: - Modes

    private func setPrivateModes(_ params: [Int], enabled: Bool) {
        for mode in params {
            switch mode {
            case 1:
                applicationCursorKeys = enabled
            case 7:
                autowrap = enabled
            case 25:
                isCursorVisible = enabled
            case 47, 1047:
                setAlternateScreen(enabled, saveRestoreCursor: false, clearOnEnter: enabled)
            case 1049:
                setAlternateScreen(enabled, saveRestoreCursor: true, clearOnEnter: enabled)
            case 2004:
                bracketedPaste = enabled
            default:
                break
            }
        }
    }

    private func setAnsiModes(_ params: [Int], enabled: Bool) {
        for mode in params {
            switch mode {
            case 4:
                insertMode = enabled
            case 20:
                lineFeedNewLineMode = enabled
            default:
                break
            }
        }
    }

    private func setAlternateScreen(_ on: Bool, saveRestoreCursor: Bool, clearOnEnter: Bool) {
        if on {
            guard activeIndex == 0 else { return }
            if saveRestoreCursor { saveCursor() }
            activeIndex = 1
            scrollTop = 0
            scrollBottom = rows - 1
            if clearOnEnter { buffers[1].clear() }
            cursorRow = 0
            cursorCol = 0
            pendingWrap = false
        } else {
            guard activeIndex == 1 else { return }
            buffers[1].clear()
            activeIndex = 0
            scrollTop = 0
            scrollBottom = rows - 1
            if saveRestoreCursor { restoreCursor() }
            pendingWrap = false
        }
    }

    private func softReset() {
        pen = Pen()
        autowrap = true
        isCursorVisible = true
        originMode = false
        insertMode = false
        lineFeedNewLineMode = false
        scrollTop = 0
        scrollBottom = rows - 1
        savedCursor = nil
        g0Graphics = false
        g1Graphics = false
        glSelectsG1 = false
        cursorRow = 0
        cursorCol = 0
        pendingWrap = false
    }

    // MARK: - SGR

    private func applySGR(_ rawParams: [Int]) {
        let params = rawParams.isEmpty ? [0] : rawParams
        var i = 0
        while i < params.count {
            let code = params[i]
            switch code {
            case 0:
                pen = Pen()
            case 1:
                pen.attributes.insert(.bold)
            case 2:
                pen.attributes.insert(.dim)
            case 3:
                pen.attributes.insert(.italic)
            case 4:
                pen.attributes.insert(.underline)
            case 5, 6:
                pen.attributes.insert(.blink)
            case 7:
                pen.attributes.insert(.inverse)
            case 8:
                pen.attributes.insert(.hidden)
            case 9:
                pen.attributes.insert(.strikethrough)
            case 22:
                pen.attributes.subtract([.bold, .dim])
            case 23:
                pen.attributes.remove(.italic)
            case 24:
                pen.attributes.remove(.underline)
            case 25:
                pen.attributes.remove(.blink)
            case 27:
                pen.attributes.remove(.inverse)
            case 28:
                pen.attributes.remove(.hidden)
            case 29:
                pen.attributes.remove(.strikethrough)
            case 30...37:
                pen.foreground = .indexed(UInt8(code - 30))
            case 38:
                if let (color, consumed) = parseExtendedColor(params, from: i) {
                    pen.foreground = color
                    i += consumed
                }
            case 39:
                pen.foreground = .default
            case 40...47:
                pen.background = .indexed(UInt8(code - 40))
            case 48:
                if let (color, consumed) = parseExtendedColor(params, from: i) {
                    pen.background = color
                    i += consumed
                }
            case 49:
                pen.background = .default
            case 90...97:
                pen.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107:
                pen.background = .indexed(UInt8(code - 100 + 8))
            default:
                break
            }
            i += 1
        }
    }

    /// Parses `38;5;n` / `38;2;r;g;b` (or `48;…`) starting at the `38`/`48` index.
    ///
    /// Returns the color and how many extra params it consumed.
    private func parseExtendedColor(_ params: [Int], from i: Int) -> (TerminalColor, Int)? {
        guard i + 1 < params.count else { return nil }
        switch params[i + 1] {
        case 5:
            guard i + 2 < params.count else { return nil }
            return (.indexed(UInt8(clamping: params[i + 2])), 2)
        case 2:
            guard i + 4 < params.count else { return nil }
            return (
                .rgb(
                    UInt8(clamping: params[i + 2]),
                    UInt8(clamping: params[i + 3]),
                    UInt8(clamping: params[i + 4])), 4
            )
        default:
            return nil
        }
    }

    // MARK: - DSR / cursor save

    private func deviceStatusReport(_ code: Int) {
        switch code {
        case 5:  // device status OK
            respond?("\u{1B}[0n")
        case 6:  // cursor position report
            respond?("\u{1B}[\(cursorRow + 1);\(cursorCol + 1)R")
        default:
            break
        }
    }

    private func saveCursor() {
        savedCursor = SavedCursor(
            row: cursorRow, col: cursorCol, pen: pen, originMode: originMode,
            g0Graphics: g0Graphics, g1Graphics: g1Graphics, glSelectsG1: glSelectsG1)
    }

    private func restoreCursor() {
        guard let saved = savedCursor else {
            cursorRow = 0
            cursorCol = 0
            return
        }
        cursorRow = clamp(saved.row, 0, rows - 1)
        cursorCol = clamp(saved.col, 0, cols - 1)
        pen = saved.pen
        originMode = saved.originMode
        g0Graphics = saved.g0Graphics
        g1Graphics = saved.g1Graphics
        glSelectsG1 = saved.glSelectsG1
        pendingWrap = false
    }

    private func setScrollRegion(top: Int, bottom: Int) {
        let t = clamp(top - 1, 0, rows - 1)
        let b = clamp(bottom - 1, 0, rows - 1)
        if t < b {
            scrollTop = t
            scrollBottom = b
        } else {
            scrollTop = 0
            scrollBottom = rows - 1
        }
        // DECSTBM homes the cursor.
        cursorRow = originMode ? scrollTop : 0
        cursorCol = 0
        pendingWrap = false
    }

    // MARK: - Scrollback / tab stops

    private func appendScrollback(_ lines: [[TerminalCell]]) {
        guard !lines.isEmpty else { return }
        scrollback.append(contentsOf: lines)
        if scrollback.count > Self.maxScrollbackRows + Self.scrollbackTrimBatch {
            scrollback.removeFirst(scrollback.count - Self.maxScrollbackRows)
        }
    }

    private func resetTabStops() {
        tabStops.removeAll(keepingCapacity: true)
        var c = 8
        while c < cols {
            tabStops.insert(c)
            c += 8
        }
    }

    private func nextTabStop(after col: Int) -> Int {
        var next = col + 1
        while next < cols - 1 && !tabStops.contains(next) {
            next += 1
        }
        return min(next, cols - 1)
    }

    // MARK: - Helpers

    /// A blank cell carrying the current background (so a colored clear works).
    private var eraseCell: TerminalCell {
        TerminalCell(scalar: " ", foreground: .default, background: pen.background, attributes: [])
    }

    private func arg(_ params: [Int], _ index: Int, _ defaultValue: Int) -> Int {
        guard index < params.count else { return defaultValue }
        let value = params[index]
        return value == 0 ? defaultValue : value
    }

    /// DEC special-graphics translation for the box-drawing range `0x5F...0x7E`.
    private static func decGraphics(_ scalar: UnicodeScalar) -> UnicodeScalar {
        switch scalar.value {
        case 0x60: return "\u{25C6}"  // ` diamond
        case 0x61: return "\u{2592}"  // a checkerboard
        case 0x62: return "\u{2409}"  // b HT
        case 0x63: return "\u{240C}"  // c FF
        case 0x64: return "\u{240D}"  // d CR
        case 0x65: return "\u{240A}"  // e LF
        case 0x66: return "\u{00B0}"  // f degree
        case 0x67: return "\u{00B1}"  // g plus/minus
        case 0x68: return "\u{2424}"  // h NL
        case 0x69: return "\u{240B}"  // i VT
        case 0x6A: return "\u{2518}"  // j ┘
        case 0x6B: return "\u{2510}"  // k ┐
        case 0x6C: return "\u{250C}"  // l ┌
        case 0x6D: return "\u{2514}"  // m └
        case 0x6E: return "\u{253C}"  // n ┼
        case 0x6F: return "\u{23BA}"  // o scan line 1
        case 0x70: return "\u{23BB}"  // p scan line 3
        case 0x71: return "\u{2500}"  // q ─
        case 0x72: return "\u{23BC}"  // r scan line 7
        case 0x73: return "\u{23BD}"  // s scan line 9
        case 0x74: return "\u{251C}"  // t ├
        case 0x75: return "\u{2524}"  // u ┤
        case 0x76: return "\u{2534}"  // v ┴
        case 0x77: return "\u{252C}"  // w ┬
        case 0x78: return "\u{2502}"  // x │
        case 0x79: return "\u{2264}"  // y ≤
        case 0x7A: return "\u{2265}"  // z ≥
        case 0x7B: return "\u{03C0}"  // { π
        case 0x7C: return "\u{2260}"  // | ≠
        case 0x7D: return "\u{00A3}"  // } £
        case 0x7E: return "\u{00B7}"  // ~ ·
        default: return scalar
        }
    }
}
