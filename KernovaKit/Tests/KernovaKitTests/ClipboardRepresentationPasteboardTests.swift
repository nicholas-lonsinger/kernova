import Foundation
import Testing

@testable import KernovaKit

/// Exercises the shared `shouldInlineOnPasteboard` predicate that both the host
/// "Copy to Mac" path and the guest inbound-paste path apply to decide whether a
/// representation rides the pasteboard inline or as a file-only URL.
@Suite("ClipboardContent.Representation.shouldInlineOnPasteboard")
struct ClipboardRepresentationPasteboardTests {
    private let dummyURL = URL(fileURLWithPath: "/tmp/kernova-clipboard-test")

    @Test("inline (filename-less) content inlines")
    func filenamelessInlines() {
        let rep = ClipboardContent.Representation(
            uti: ClipboardContent.utf8TextUTI, data: Data("hi".utf8))
        #expect(rep.shouldInlineOnPasteboard)
    }

    @Test("an image file payload inlines")
    func imageFileInlines() {
        let rep = ClipboardContent.Representation(
            uti: "public.png", fileURL: dummyURL, byteCount: 10, filename: "photo.png")
        #expect(rep.shouldInlineOnPasteboard)
    }

    @Test("a non-image file payload is file-only")
    func nonImageFileIsFileOnly() {
        let rep = ClipboardContent.Representation(
            uti: "public.plain-text", fileURL: dummyURL, byteCount: 10, filename: "notes.txt")
        #expect(!rep.shouldInlineOnPasteboard)
    }

    @Test("a directory payload is always file-only")
    func directoryIsFileOnly() {
        // Even with an image-ish UTI, a directory never inlines.
        let rep = ClipboardContent.Representation(
            uti: "public.folder", fileURL: dummyURL, byteCount: 10, filename: "Pictures",
            isDirectory: true)
        #expect(!rep.shouldInlineOnPasteboard)
    }
}
