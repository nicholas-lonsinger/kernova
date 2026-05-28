import Testing

@testable import Kernova

@Suite("TerminalBuffer Tests")
struct TerminalBufferTests {
    private func filled(cols: Int, rows: Int) -> TerminalBuffer {
        var buffer = TerminalBuffer(cols: cols, rows: rows)
        for r in 0..<rows {
            let marker = UnicodeScalar(UInt8(0x30 + (r % 10)))  // '0'..'9'
            buffer.setCell(TerminalCell(scalar: marker), row: r, col: 0)
        }
        return buffer
    }

    @Test("scrollUp returns the lines pushed off the top and blanks the bottom")
    func scrollUp() {
        var buffer = filled(cols: 4, rows: 4)  // rows marked 0,1,2,3 in col 0
        let removed = buffer.scrollUp(top: 0, bottom: 3, count: 1)
        #expect(removed.count == 1)
        #expect(removed[0][0].scalar == "0")
        #expect(buffer.cell(row: 0, col: 0).scalar == "1")
        #expect(buffer.cell(row: 3, col: 0).scalar == " ")  // new blank line
    }

    @Test("scrollUp respects a partial region")
    func scrollUpRegion() {
        var buffer = filled(cols: 4, rows: 4)
        buffer.scrollUp(top: 0, bottom: 2, count: 1)  // region rows 0..2, row 3 untouched
        #expect(buffer.cell(row: 0, col: 0).scalar == "1")
        #expect(buffer.cell(row: 2, col: 0).scalar == " ")
        #expect(buffer.cell(row: 3, col: 0).scalar == "3")  // outside region
    }

    @Test("scrollDown inserts blanks at the top of the region")
    func scrollDown() {
        var buffer = filled(cols: 4, rows: 4)
        buffer.scrollDown(top: 0, bottom: 3, count: 1)
        #expect(buffer.cell(row: 0, col: 0).scalar == " ")
        #expect(buffer.cell(row: 1, col: 0).scalar == "0")
    }

    @Test("eraseInRow erases the requested column span only")
    func eraseInRow() {
        var buffer = TerminalBuffer(cols: 6, rows: 1)
        for c in 0..<6 { buffer.setCell(TerminalCell(scalar: "X"), row: 0, col: c) }
        buffer.eraseInRow(0, from: 2, through: 4)
        #expect(buffer.cell(row: 0, col: 1).scalar == "X")
        #expect(buffer.cell(row: 0, col: 2).scalar == " ")
        #expect(buffer.cell(row: 0, col: 4).scalar == " ")
        #expect(buffer.cell(row: 0, col: 5).scalar == "X")
    }

    @Test("insertLines pushes lines down within the region")
    func insertLines() {
        var buffer = filled(cols: 4, rows: 4)
        buffer.insertLines(at: 1, count: 1, bottom: 3)
        #expect(buffer.cell(row: 0, col: 0).scalar == "0")
        #expect(buffer.cell(row: 1, col: 0).scalar == " ")  // inserted blank
        #expect(buffer.cell(row: 2, col: 0).scalar == "1")  // pushed down
    }

    @Test("deleteLines pulls lines up and blanks the bottom")
    func deleteLines() {
        var buffer = filled(cols: 4, rows: 4)
        buffer.deleteLines(at: 1, count: 1, bottom: 3)
        #expect(buffer.cell(row: 1, col: 0).scalar == "2")  // pulled up
        #expect(buffer.cell(row: 3, col: 0).scalar == " ")  // blanked
    }

    @Test("insertChars and deleteChars shift within the row")
    func insertDeleteChars() {
        var buffer = TerminalBuffer(cols: 5, rows: 1)
        for (c, ch) in "ABCDE".unicodeScalars.enumerated() {
            buffer.setCell(TerminalCell(scalar: ch), row: 0, col: c)
        }
        buffer.insertChars(row: 0, col: 1, count: 1)
        #expect(buffer.cell(row: 0, col: 0).scalar == "A")
        #expect(buffer.cell(row: 0, col: 1).scalar == " ")
        #expect(buffer.cell(row: 0, col: 2).scalar == "B")

        buffer.deleteChars(row: 0, col: 1, count: 1)
        #expect(buffer.cell(row: 0, col: 1).scalar == "B")
    }

    @Test("resize grows and shrinks, preserving top-left content")
    func resize() {
        var buffer = filled(cols: 4, rows: 4)
        buffer.resize(cols: 6, rows: 6)
        #expect(buffer.cols == 6)
        #expect(buffer.rowCount == 6)
        #expect(buffer.cell(row: 0, col: 0).scalar == "0")  // preserved
        #expect(buffer.cell(row: 0, col: 5).scalar == " ")  // padded
        #expect(buffer.cell(row: 5, col: 0).scalar == " ")  // padded row

        buffer.resize(cols: 2, rows: 2)
        #expect(buffer.cols == 2)
        #expect(buffer.rowCount == 2)
        #expect(buffer.cell(row: 0, col: 0).scalar == "0")  // still there
    }
}
