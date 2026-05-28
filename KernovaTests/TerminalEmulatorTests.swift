import Foundation
import Testing

@testable import Kernova

@Suite("TerminalEmulator Tests")
@MainActor
struct TerminalEmulatorTests {
    private func makeEmulator(cols: Int = 80, rows: Int = 24) -> TerminalEmulator {
        TerminalEmulator(cols: cols, rows: rows)
    }

    private func cell(_ emulator: TerminalEmulator, _ row: Int, _ col: Int) -> TerminalCell {
        emulator.displayRows(scrollOffset: 0)[row][col]
    }

    private func feed(_ emulator: TerminalEmulator, _ string: String) {
        emulator.feed(Data(string.utf8))
    }

    // MARK: - SGR

    @Test("SGR applies bold and indexed foreground to written cells")
    func sgrApplies() {
        let e = makeEmulator()
        feed(e, "\u{1B}[1;31mX")
        let c = cell(e, 0, 0)
        #expect(c.scalar == "X")
        #expect(c.attributes.contains(.bold))
        #expect(c.foreground == .indexed(1))
    }

    @Test("SGR 0 resets the pen")
    func sgrReset() {
        let e = makeEmulator()
        feed(e, "\u{1B}[1;31mA\u{1B}[0mB")
        #expect(cell(e, 0, 0).attributes.contains(.bold))
        #expect(cell(e, 0, 1).attributes.isEmpty)
        #expect(cell(e, 0, 1).foreground == .default)
    }

    @Test("SGR 256-color foreground parses 38;5;n")
    func sgr256() {
        let e = makeEmulator()
        feed(e, "\u{1B}[38;5;200mZ")
        #expect(cell(e, 0, 0).foreground == .indexed(200))
    }

    // MARK: - Cursor

    @Test("CUP to the far corner clamps to grid bounds")
    func cupClamps() {
        let e = makeEmulator()
        feed(e, "\u{1B}[32766;32766H")
        #expect(e.cursorRow == 23)
        #expect(e.cursorCol == 79)
        feed(e, "Z")
        #expect(cell(e, 23, 79).scalar == "Z")
    }

    @Test("Autowrap defers to the next character, then wraps to the next line")
    func autowrap() {
        let e = makeEmulator()
        feed(e, String(repeating: "A", count: 80))
        #expect(e.cursorRow == 0)  // deferred wrap — not yet moved
        #expect(cell(e, 0, 79).scalar == "A")
        feed(e, "B")
        #expect(cell(e, 1, 0).scalar == "B")
    }

    // MARK: - Erase

    @Test("ED mode 2 clears the whole screen")
    func eraseDisplay() {
        let e = makeEmulator()
        feed(e, "hello\u{1B}[2J")
        #expect(cell(e, 0, 0).scalar == " ")
    }

    // MARK: - DSR / DA replies

    @Test("DSR 6 reports the 1-based cursor position")
    func dsrCursorReport() {
        let e = makeEmulator()
        var responses: [String] = []
        e.respond = { responses.append($0) }
        feed(e, "\u{1B}[5;10H\u{1B}[6n")
        #expect(responses == ["\u{1B}[5;10R"])
    }

    @Test("DSR is answered from the default 80x24 size before any resize")
    func dsrDefaultSize() {
        let e = makeEmulator()
        var responses: [String] = []
        e.respond = { responses.append($0) }
        feed(e, "\u{1B}[32766;32766H\u{1B}[6n")
        #expect(responses == ["\u{1B}[24;80R"])
    }

    @Test("Primary device attributes reply identifies as VT102")
    func primaryDA() {
        let e = makeEmulator()
        var responses: [String] = []
        e.respond = { responses.append($0) }
        feed(e, "\u{1B}[c")
        #expect(responses == ["\u{1B}[?6c"])
    }

    // MARK: - DECSTR

    @Test("DECSTR resets the pen but does not clear the screen")
    func decstrSoftReset() {
        let e = makeEmulator()
        feed(e, "ABC\u{1B}[31m\u{1B}[!pQ")
        #expect(cell(e, 0, 2).scalar == "C")  // screen not cleared
        #expect(cell(e, 0, 0).scalar == "Q")  // cursor homed, Q written
        #expect(cell(e, 0, 0).foreground == .default)  // pen reset
    }

    // MARK: - Modes

    @Test("DEC private mode 25 toggles cursor visibility")
    func cursorVisibility() {
        let e = makeEmulator()
        feed(e, "\u{1B}[?25l")
        #expect(e.isCursorVisible == false)
        feed(e, "\u{1B}[?25h")
        #expect(e.isCursorVisible == true)
    }

    // MARK: - Alt-screen + scrollback freeze

    @Test("Alternate screen does not grow the primary scrollback")
    func altScreenFreezesScrollback() {
        let e = makeEmulator()
        feed(e, "\u{1B}[2J\u{1B}[H")
        for i in 0..<40 { feed(e, "line\(i)\r\n") }
        let frozenCount = e.scrollbackCount
        #expect(frozenCount > 0)

        feed(e, "\u{1B}[?1049h")  // enter alt screen
        for i in 0..<20 { feed(e, "alt\(i)\r\n") }
        #expect(e.scrollbackCount == 0)  // alt screen exposes no scrollback

        feed(e, "\u{1B}[?1049l")  // exit alt screen
        // The primary scrollback was frozen during alt — unchanged after returning.
        #expect(e.scrollbackCount == frozenCount)
    }

    // MARK: - RIS

    @Test("RIS clears the screen, scrollback, and homes the cursor")
    func fullReset() {
        let e = makeEmulator()
        feed(e, "\u{1B}[2J\u{1B}[H")
        for i in 0..<40 { feed(e, "line\(i)\r\n") }
        feed(e, "\u{1B}c")
        #expect(e.scrollbackCount == 0)
        #expect(e.cursorRow == 0)
        #expect(e.cursorCol == 0)
        #expect(cell(e, 0, 0).scalar == " ")
    }

    // MARK: - Scrolling pushes to scrollback

    @Test("Scrolling off the top of the primary screen accumulates scrollback")
    func scrollbackAccumulates() {
        let e = makeEmulator(cols: 10, rows: 3)
        for i in 0..<10 { feed(e, "row\(i)\r\n") }
        #expect(e.scrollbackCount > 0)
        // Oldest visible-from-history line should be reachable via scrollOffset.
        let top = e.displayRows(scrollOffset: e.scrollbackCount)
        #expect(top.count == 3)
    }
}
