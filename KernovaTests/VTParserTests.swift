import Foundation
import Testing

@testable import Kernova

/// A `TerminalPerformer` that records every dispatched event so tests can assert
/// the exact decode sequence without a grid.
@MainActor
private final class RecordingPerformer: TerminalPerformer {
    enum Event: Equatable {
        case print(UnicodeScalar)
        case execute(UInt8)
        case csi(prefix: UInt8?, params: [Int], intermediates: [UInt8], final: UInt8)
        case esc(intermediates: [UInt8], final: UInt8)
        case osc([UInt8])
    }

    var events: [Event] = []

    func print(_ scalar: UnicodeScalar) { events.append(.print(scalar)) }
    func execute(_ control: UInt8) { events.append(.execute(control)) }
    func csiDispatch(prefix: UInt8?, params: [Int], intermediates: [UInt8], final: UInt8) {
        events.append(.csi(prefix: prefix, params: params, intermediates: intermediates, final: final))
    }
    func escDispatch(intermediates: [UInt8], final: UInt8) {
        events.append(.esc(intermediates: intermediates, final: final))
    }
    func oscDispatch(_ data: [UInt8]) { events.append(.osc(data)) }

    /// Concatenation of all printed scalars.
    var printedText: String {
        String(String.UnicodeScalarView(events.compactMap { if case .print(let s) = $0 { s } else { nil } }))
    }

    var csiEvents: [Event] {
        events.filter { if case .csi = $0 { true } else { false } }
    }
}

@Suite("VTParser Tests")
@MainActor
struct VTParserTests {
    private func parse(_ string: String) -> RecordingPerformer {
        let performer = RecordingPerformer()
        var parser = VTParser()
        parser.feed(Data(string.utf8), to: performer)
        return performer
    }

    private func parse(_ bytes: [UInt8]) -> RecordingPerformer {
        let performer = RecordingPerformer()
        var parser = VTParser()
        parser.feed(Data(bytes), to: performer)
        return performer
    }

    // MARK: - Printables & controls

    @Test("Plain ASCII prints through")
    func plainASCII() {
        #expect(parse("hello").printedText == "hello")
    }

    @Test("C0 controls are executed, not printed")
    func c0Controls() {
        let p = parse("a\r\nb")
        #expect(
            p.events == [
                .print("a"), .execute(0x0D), .execute(0x0A), .print("b"),
            ])
    }

    // MARK: - CSI parsing

    @Test("CSI with parameters dispatches with parsed ints")
    func csiParams() {
        let p = parse("\u{1B}[1;2H")
        #expect(p.events == [.csi(prefix: nil, params: [1, 2], intermediates: [], final: 0x48)])
    }

    @Test("CSI private prefix is captured")
    func csiPrivatePrefix() {
        let p = parse("\u{1B}[?25h")
        #expect(p.events == [.csi(prefix: 0x3F, params: [25], intermediates: [], final: 0x68)])
    }

    @Test("CSI intermediate byte is captured (DECSTR)")
    func csiIntermediate() {
        let p = parse("\u{1B}[!p")
        #expect(p.events == [.csi(prefix: nil, params: [], intermediates: [0x21], final: 0x70)])
    }

    @Test("CSI parameter count is capped at 16")
    func csiParamCap() {
        let nums = (1...20).map(String.init).joined(separator: ";")
        let p = parse("\u{1B}[\(nums)m")
        guard case .csi(_, let params, _, _) = p.events.first else {
            Issue.record("expected a CSI event")
            return
        }
        #expect(params == Array(1...16))
    }

    @Test("CSI parameter value saturates at 65535")
    func csiParamSaturates() {
        let p = parse("\u{1B}[99999999H")
        guard case .csi(_, let params, _, _) = p.events.first else {
            Issue.record("expected a CSI event")
            return
        }
        #expect(params == [65535])
    }

    @Test("Empty CSI parameters dispatch with no params")
    func csiNoParams() {
        let p = parse("\u{1B}[H")
        #expect(p.events == [.csi(prefix: nil, params: [], intermediates: [], final: 0x48)])
    }

    // MARK: - OSC

    @Test("OSC terminated by BEL dispatches its payload")
    func oscBEL() {
        let p = parse("\u{1B}]0;title\u{07}")
        #expect(p.events == [.osc(Array("0;title".utf8))])
    }

    @Test("OSC terminated by ST dispatches its payload")
    func oscST() {
        let p = parse("\u{1B}]2;hi\u{1B}\\")
        #expect(p.events.first == .osc(Array("2;hi".utf8)))
    }

    @Test("OSC payload is capped at maxOSCLength")
    func oscOverflow() {
        let p = parse("\u{1B}]" + String(repeating: "A", count: 5000) + "\u{07}")
        guard case .osc(let data) = p.events.first else {
            Issue.record("expected an OSC event")
            return
        }
        #expect(data.count == VTParser.maxOSCLength)
    }

    // MARK: - DCS (swallowed)

    @Test("DCS is swallowed; trailing text still prints")
    func dcsSwallowed() {
        let p = parse("\u{1B}P+q6E616D65\u{1B}\\X")
        // No payload bytes leak as prints; only the trailing 'X' prints.
        #expect(p.printedText == "X")
        #expect(!p.events.contains(.print("6")))
        #expect(!p.events.contains(.print("q")))
    }

    // MARK: - UTF-8

    @Test("Multibyte UTF-8 split across feeds yields one scalar")
    func utf8SplitAcrossFeeds() {
        let performer = RecordingPerformer()
        var parser = VTParser()
        parser.feed(Data([0xC3]), to: performer)  // first byte of é (U+00E9)
        #expect(performer.events.isEmpty)
        parser.feed(Data([0xA9]), to: performer)  // continuation
        #expect(performer.events == [.print("é")])
    }

    @Test("Invalid UTF-8 lead followed by ASCII yields replacement then the ASCII")
    func invalidUTF8() {
        let p = parse([0xC3, 0x41])  // bad: lead byte then non-continuation 'A'
        #expect(p.events == [.print("\u{FFFD}"), .print("A")])
    }

    @Test("Stray continuation byte yields replacement")
    func strayContinuation() {
        let p = parse([0x80])
        #expect(p.events == [.print("\u{FFFD}")])
    }

    // MARK: - Aborts

    @Test("CAN aborts an in-progress CSI sequence")
    func canAborts() {
        let p = parse("\u{1B}[12\u{18}3")
        #expect(p.csiEvents.isEmpty)
        #expect(p.printedText == "3")
    }

    @Test("ESC mid-CSI starts a fresh escape sequence")
    func escMidCSI() {
        let p = parse("\u{1B}[12\u{1B}[5H")
        // The first CSI is abandoned; only the second dispatches.
        #expect(p.events == [.csi(prefix: nil, params: [5], intermediates: [], final: 0x48)])
    }
}
