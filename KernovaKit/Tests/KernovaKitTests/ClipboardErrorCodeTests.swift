import Testing

@testable import KernovaKit

/// Pins the wire spelling of every clipboard failure code, which the producing
/// side sends and the host's clipboard window maps to a message: a renamed raw
/// value silently degrades a real failure to the generic fallback sentence.
@Suite("ClipboardErrorCode", .admissionGated)
struct ClipboardErrorCodeTests {
    @Test("every code round-trips through its wire spelling")
    func roundTrips() {
        for code in ClipboardErrorCode.allCases {
            #expect(ClipboardErrorCode(rawValue: code.rawValue) == code)
        }
    }

    @Test("the wire spellings are the ones both sides carry")
    func rawValues() {
        #expect(ClipboardErrorCode.pasteTooLarge.rawValue == "clipboard.paste.too.large")
        #expect(ClipboardErrorCode.pasteDiskFull.rawValue == "clipboard.paste.disk.full")
        #expect(ClipboardErrorCode.pasteTimeout.rawValue == "clipboard.paste.timeout")
        #expect(ClipboardErrorCode.pasteFailed.rawValue == "clipboard.paste.failed")
        #expect(ClipboardErrorCode.copyTooLarge.rawValue == "clipboard.copy.too.large")
    }

    @Test("every code carries the prefix the host's error routing gates on")
    func prefixed() {
        for code in ClipboardErrorCode.allCases {
            #expect(code.rawValue.hasPrefix("clipboard."))
        }
    }

    @Test("an unknown code maps to no case rather than a neighbouring one")
    func unknownCode() {
        #expect(ClipboardErrorCode(rawValue: "clipboard.transfer.send.failure") == nil)
    }
}
