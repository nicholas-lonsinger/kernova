import Foundation
import Testing

@testable import Kernova

/// Regression test for issue #249: the Serial Console rendered raw ANSI/VT
/// escape sequences as literal text. Feeds the exact garbled boot banner from
/// the issue and asserts the emulator produces a clean grid with zero escape
/// residue, and that the guest's cursor probes are answered.
@Suite("Terminal Issue #249 Regression")
@MainActor
struct TerminalIssue249Tests {
    /// The agetty/systemd banner from the issue: DECSTR, OSC palette reset, SGR
    /// reset, autowrap, cursor positioning, two cursor-position probes, a
    /// far-corner size probe, and a DCS termcap (XTGETTCAP) query — followed by
    /// the actual login prompt.
    private let banner =
        "\u{1B}[!p"  // DECSTR soft reset
        + "\u{1B}]104\u{1B}\\"  // OSC 104 reset palette, ST-terminated
        + "\u{1B}[0m"  // SGR reset
        + "\u{1B}[?7h"  // autowrap on
        + "\u{1B}[1G"  // cursor to column 1
        + "\u{1B}[0J"  // erase to end of display
        + "\u{1B}[6n"  // DSR cursor-position report
        + "\u{1B}[32766;32766H"  // move to far corner (size probe)
        + "\u{1B}[6n"  // DSR again
        + "\u{1B}P+q6E616D65\u{1B}\\"  // DCS XTGETTCAP query ("name"), ST-terminated
        + "\r\npanda-vm-Platform login: "

    @Test("The garbled banner renders cleanly with no escape residue")
    func bannerRendersCleanly() {
        let e = TerminalEmulator(cols: 80, rows: 24)
        e.feed(Data(banner.utf8))

        let visible = e.visibleText()
        #expect(visible.contains("login:"))

        // None of the control-sequence residue should appear as literal text.
        for residue in ["\u{1B}", "[", "]104", "104", "6n", "+q", "!p", "?7h", "0J"] {
            #expect(!visible.contains(residue), "rendered text leaked control residue: \(residue)")
        }
    }

    @Test("Both cursor-position probes are answered to the guest")
    func cursorProbesAnswered() {
        let e = TerminalEmulator(cols: 80, rows: 24)
        var responses: [String] = []
        e.respond = { responses.append($0) }
        e.feed(Data(banner.utf8))

        // First [6n] after [1G: cursor at row 1, col 1. Second after the
        // far-corner move: clamped to 24×80.
        #expect(responses == ["\u{1B}[1;1R", "\u{1B}[24;80R"])
    }

    @Test("Full history (scrollback + screen) is also free of escape residue")
    func fullTextClean() {
        let e = TerminalEmulator(cols: 80, rows: 24)
        e.feed(Data(banner.utf8))
        let full = e.fullText()
        #expect(full.contains("login:"))
        #expect(!full.contains("\u{1B}"))
        #expect(!full.contains("104"))
    }
}
