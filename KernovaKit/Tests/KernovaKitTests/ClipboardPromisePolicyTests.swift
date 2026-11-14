import Foundation
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaKit

/// Unit tests for the receive-side gate both peers apply to an offer's items
/// before a byte of it crosses.
@Suite("ClipboardPromisePolicy", .caseScoped)
struct ClipboardPromisePolicyTests {
    private func inline(_ uti: String = ClipboardContent.utf8TextUTI, size: Int = 8) -> Representation {
        .make(TypeDescriptor(appleUTI: uti), .inline, size: size)
    }

    private func file(_ name: String, size: Int = 8) -> Representation {
        .make(TypeDescriptor(appleUTI: "public.data"), .file, size: size, name: name)
    }

    private func item(_ representations: Representation...) -> OfferedItem {
        var item = OfferedItem()
        item.representations = representations
        return item
    }

    // MARK: - keeps

    @Test("an inline type no Mac pasteboard names is not kept; a MIME type alone maps")
    func keepsOnlyTypesAMacNames() {
        var windowsOnly = TypeDescriptor()
        windowsOnly.native = [NativeTypeNamespace.windowsClipboardFormat.qualified("CF_DIB")]
        #expect(!ClipboardPromisePolicy.keeps(.make(windowsOnly, .inline, size: 8)))

        var mimeOnly = TypeDescriptor()
        mimeOnly.mime = "image/png"
        #expect(mimeOnly.appleUTI == "public.png")
        #expect(ClipboardPromisePolicy.keeps(.make(mimeOnly, .inline, size: 8)))
    }

    @Test("an unrecognized storage is not kept")
    func dropsUnspecifiedStorage() {
        #expect(!ClipboardPromisePolicy.keeps(.make(TypeDescriptor(appleUTI: "public.data"), .unspecified, size: 8)))
    }

    // MARK: - servesFileURL

    @Test("only a kept FILE or FOLDER serves .fileURL")
    func servesFileURLForFilesAndFolders() {
        #expect(ClipboardPromisePolicy.servesFileURL(file("photo.png")))
        #expect(
            ClipboardPromisePolicy.servesFileURL(
                .make(TypeDescriptor(appleUTI: "public.folder"), .folder, size: 0, name: "Album")))
        #expect(!ClipboardPromisePolicy.servesFileURL(inline()))
        #expect(!ClipboardPromisePolicy.servesFileURL(inline("public.file-url")))
    }

    // MARK: - Paste budget

    @Test("the paste-bound total counts only the .fileURL-serving reps")
    func totalsOnlyFileServingReps() {
        let items = [
            item(file("a.bin", size: 100)),
            item(inline(size: 200)),
            item(file("b.bin", size: 300), file("c.bin", size: 400)),
        ]
        #expect(ClipboardPromisePolicy.pasteBudget(items, limit: .max).total == 400)
    }

    @Test("a set exactly at the cap is within budget, one byte over is not")
    func atCapIsWithinBudget() {
        let items = [item(file("a.bin", size: 100))]
        #expect(!ClipboardPromisePolicy.pasteBudget(items, limit: 100).exceeds)
        #expect(ClipboardPromisePolicy.pasteBudget(items, limit: 99).exceeds)
        #expect(ClipboardPromisePolicy.pasteBudget(items, limit: 99).limit == 99)
    }
}
