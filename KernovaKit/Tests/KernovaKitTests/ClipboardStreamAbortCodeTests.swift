import KernovaTestSupport
import Testing

@testable import KernovaKit

/// Pins the wire spelling of every stream abort code and the set that retires a
/// transfer quietly: a renamed raw value either silences a real failure or
/// starts reporting a routine teardown, and neither shows up as a build error.
@Suite("ClipboardStreamAbortCode", .caseScoped)
struct ClipboardStreamAbortCodeTests {
    @Test("the wire spellings are the ones both sides carry")
    func rawValues() {
        #expect(ClipboardStreamAbortCode.requestStale.rawValue == "request.stale")
        #expect(ClipboardStreamAbortCode.requestRange.rawValue == "request.range")
        #expect(ClipboardStreamAbortCode.requestUTI.rawValue == "request.uti")
        #expect(ClipboardStreamAbortCode.requestCancelled.rawValue == "request.cancelled")
        #expect(ClipboardStreamAbortCode.cancelled.rawValue == "cancelled")
        #expect(ClipboardStreamAbortCode.userCancelled.rawValue == "user.cancelled")
        #expect(ClipboardStreamAbortCode.superseded.rawValue == "superseded")
        #expect(ClipboardStreamAbortCode.readError.rawValue == "read.error")
        #expect(ClipboardStreamAbortCode.sendFailed.rawValue == "send.failed")
        #expect(ClipboardStreamAbortCode.sizeOverrun.rawValue == "size.overrun")
        #expect(ClipboardStreamAbortCode.sizeMismatch.rawValue == "size.mismatch")
        #expect(ClipboardStreamAbortCode.digestMismatch.rawValue == "digest.mismatch")
        #expect(ClipboardStreamAbortCode.payloadUnsupported.rawValue == "payload.unsupported")
        #expect(ClipboardStreamAbortCode.payloadInvalid.rawValue == "payload.invalid")
        #expect(ClipboardStreamAbortCode.diskFull.rawValue == "disk.full")
        #expect(ClipboardStreamAbortCode.writeError.rawValue == "write.error")
        #expect(ClipboardStreamAbortCode.extractError.rawValue == "extract.error")
        #expect(ClipboardStreamAbortCode.stageError.rawValue == "stage.error")
        #expect(ClipboardStreamAbortCode.mapError.rawValue == "map.error")
        #expect(ClipboardStreamAbortCode.stallTimeout.rawValue == "stall.timeout")
        #expect(ClipboardStreamAbortCode.pasteTimeout.rawValue == "paste.timeout")
    }

    @Test("exactly the teardown and supersession codes retire quietly")
    func retiringMembership() {
        #expect(
            ClipboardStreamAbortCode.retiring == [
                .cancelled, .superseded, .requestStale, .userCancelled,
            ])
    }

    @Test("a code this build does not define is reported, never swallowed")
    func undefinedCodeIsReported() {
        let info = ClipboardStreamAbortInfo(
            transferID: 1, rawCode: "archive.error", message: "x", neededBytes: nil,
            availableBytes: nil)
        #expect(info.code == nil)
        #expect(info.rawCode == "archive.error")
        #expect(!info.isRetiring)
    }

    @Test("a decoded known code resolves to its case and keeps the peer's spelling")
    func decodedKnownCode() {
        let info = ClipboardStreamAbortInfo(
            transferID: 1, rawCode: "disk.full", message: "x", neededBytes: nil,
            availableBytes: nil)
        #expect(info.code == .diskFull)
        #expect(info.rawCode == "disk.full")
    }
}
